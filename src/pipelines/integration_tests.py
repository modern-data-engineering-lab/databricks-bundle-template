####################################################
# Pipeline integration tests
####################################################
# Deliberately a plain .py file, not a "# Databricks notebook source" — Asset Bundles convert
# notebook-source .py files into NOTEBOOK workspace objects on sync, and that conversion has a
# propagation race that pipeline library loading can outrun (intermittent
# LIBRARY_FILE_NOT_FOUND on Free Edition serverless). Plain files skip that conversion.
#
# Runs *inside* the Lakeflow Declarative Pipeline itself (it's registered as a pipeline
# library in `resources/pipeline/example_etl_pipeline.pipeline.yml`), using expectations
# to assert on the actual bronze/silver/gold tables the pipeline just built — not mocks.
#
# In dev/staging this checks exact row counts against the known size of the sample data
# for that target. In prod, row counts vary run to run, so only the gold table's shape is
# checked (i.e. "did this run produce sane categories," not "did it produce N rows").
#
# See "Portable and reusable expectations":
# https://docs.databricks.com/en/delta-live-tables/expectation-patterns.html

import dlt

target = spark.conf.get("target")

# Expected row counts for the bundled sample data (sample_data/orders_sample.csv, 20 rows)
# in each non-prod target. Update these if you swap in your own sample data — staging is
# assumed to hold a larger duplicate of the same shape.
target_integration_tests_validation = {
    "dev": {
        "orders_bronze": {"total_rows": 20},
        "orders_silver": {"total_rows": 20},
    },
    "staging": {
        "orders_bronze": {"total_rows": 200},
        "orders_silver": {"total_rows": 200},
    },
}

if target in target_integration_tests_validation:
    expected_counts = target_integration_tests_validation[target]
    total_expected_bronze = expected_counts["orders_bronze"]["total_rows"]
    total_expected_silver = expected_counts["orders_silver"]["total_rows"]


def test_count_table_total_rows(table_name, total_count, target):
    """Materialized view asserting an exact row count for a table in a given target."""

    @dlt.table(
        name=f"TEST_{target}_{table_name}_total_rows_verification",
        comment=f"Confirms all rows were ingested into {table_name} for {target}.",
    )
    @dlt.expect_all_or_fail({"valid_count": f"total_rows = {total_count}"})
    def count_table_total_rows():
        return spark.sql(f"SELECT COUNT(*) AS total_rows FROM LIVE.{table_name}")


def test_gold_table_columns():
    """Confirms the gold table only ever contains the expected category values."""
    check_gold_columns = {
        "valid_region": "region in ('NA', 'EMEA', 'Other')",
        "valid_value_band": "order_value_band in ('small', 'medium', 'large', 'unknown')",
    }

    @dlt.table(comment="Checks region and order_value_band values in the gold table.")
    @dlt.expect_all_or_fail(check_gold_columns)
    def test_gold_table_categories():
        return dlt.read("sales_by_region_band").select("region", "order_value_band")


if target in ("dev", "staging"):
    test_count_table_total_rows("orders_bronze", total_expected_bronze, target)
    test_count_table_total_rows("orders_silver", total_expected_silver, target)
    test_gold_table_columns()
elif target == "prod":
    test_gold_table_columns()
