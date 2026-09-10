####################################################
# Bronze/silver layers for the example orders pipeline
####################################################
# Deliberately a plain .py file, not a "# Databricks notebook source" — Asset Bundles convert
# notebook-source .py files into NOTEBOOK workspace objects on sync, and that conversion has a
# propagation race that pipeline library loading can outrun (intermittent
# LIBRARY_FILE_NOT_FOUND on Free Edition serverless). Plain files skip that conversion.
# A minimal Lakeflow Declarative Pipeline (formerly DLT) showing expectations, streaming
# ingestion via Auto Loader, and a silver transform. Deliberately small — this is a
# deployment-shape template, not a full pipeline reference; see finance-lakehouse-platform
# for the richer medallion build.
#
# - Manage data quality with pipeline expectations:
#   https://docs.databricks.com/en/delta-live-tables/expectations.html
# - Expectation recommendations and advanced patterns:
#   https://docs.databricks.com/en/delta-live-tables/expectation-patterns.html

import sys

import pyspark.sql.functions as F
from pyspark import pipelines as dp

sys.path.append("../.")
from helpers import transform_functions

# Set via the pipeline's `configuration` block in
# resources/pipeline/example_etl_pipeline.pipeline.yml, so this notebook runs unmodified
# against dev, staging, or prod.
target = spark.conf.get("target")
raw_data_path = spark.conf.get("raw_data_path")


valid_rows = {
    "not_null_order_id": "order_id IS NOT NULL",
    "valid_order_date": "order_date IS NOT NULL",
}


@dp.table(
    comment="Raw orders ingested from the landing volume, with file-level metadata attached.",
    table_properties={"quality": "bronze"},
)
@dp.expect_all_or_drop(valid_rows)
def orders_bronze():
    return (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", "csv")
        .option("header", "true")
        .schema(transform_functions.get_orders_schema())
        .load(raw_data_path)
        .select(
            "*",
            "_metadata.file_name",
            "_metadata.file_modification_time",
            F.current_timestamp().alias("ingested_at"),
        )
    )


@dp.table(
    comment="Cleaned orders with region normalized and order value bucketed.",
    table_properties={"quality": "silver"},
)
def orders_silver():
    return (
        dp.read_stream("orders_bronze")
        .withColumn("region", transform_functions.normalize_region("region"))
        .withColumn("order_value_band", transform_functions.order_value_band("amount"))
        .drop("file_name", "file_modification_time", "ingested_at")
    )
