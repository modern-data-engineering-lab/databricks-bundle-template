import os

import pytest
from pyspark.sql import SparkSession
from pyspark.sql.functions import col
from pyspark.sql.types import (
    DateType,
    DoubleType,
    IntegerType,
    StringType,
    StructField,
    StructType,
)
from pyspark.testing.utils import assertDataFrameEqual, assertSchemaEqual

from src.helpers import transform_functions


@pytest.fixture(scope="session")
def spark():
    # On Databricks (including serverless), a Spark Connect session is already configured via
    # env vars before this code runs — explicitly setting a local master would conflict with
    # it. Only force local[2] when running outside Databricks (e.g. in GitHub Actions CI).
    builder = SparkSession.builder.appName("unit-tests")
    if "DATABRICKS_RUNTIME_VERSION" not in os.environ:
        builder = builder.master("local[2]")
    return builder.getOrCreate()


def test_get_orders_schema_matches_expected():
    expected_schema = StructType(
        [
            StructField("order_id", IntegerType(), True),
            StructField("customer_id", IntegerType(), True),
            StructField("order_date", DateType(), True),
            StructField("region", StringType(), True),
            StructField("category", StringType(), True),
            StructField("amount", DoubleType(), True),
        ]
    )

    assertSchemaEqual(transform_functions.get_orders_schema(), expected_schema)


def test_normalize_region_maps_known_variants(spark):
    data = [("US",), ("USA",), ("UK",), ("Europe",), ("Narnia",), (None,)]
    sample_df = spark.createDataFrame(data, ["region"])

    actual_df = sample_df.withColumn(
        "normalized", transform_functions.normalize_region("region")
    )

    expected_df = spark.createDataFrame(
        [
            ("US", "NA"),
            ("USA", "NA"),
            ("UK", "EMEA"),
            ("Europe", "EMEA"),
            ("Narnia", "Other"),
            (None, "Other"),
        ],
        schema=["region", "normalized"],
    )

    assertDataFrameEqual(
        actual_df.select(col("normalized")), expected_df.select(col("normalized"))
    )


def test_order_value_band_buckets_amounts(spark):
    data = [(0.0,), (49.99,), (50.0,), (199.99,), (200.0,), (None,)]
    sample_df = spark.createDataFrame(data, ["amount"])

    actual_df = sample_df.withColumn(
        "band", transform_functions.order_value_band("amount")
    )

    expected_df = spark.createDataFrame(
        [
            (0.0, "small"),
            (49.99, "small"),
            (50.0, "medium"),
            (199.99, "medium"),
            (200.0, "large"),
            (None, "unknown"),
        ],
        schema=["amount", "band"],
    )

    assertDataFrameEqual(
        actual_df.select(col("band")), expected_df.select(col("band"))
    )
