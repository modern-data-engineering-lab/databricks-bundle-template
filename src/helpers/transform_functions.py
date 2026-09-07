"""Pure transform helpers used by the pipeline, kept separate from it so they're unit-testable
without a running pipeline or a live workspace — see tests/unit_tests/."""

from pyspark.sql import Column
from pyspark.sql.functions import col, when
from pyspark.sql.types import DateType, DoubleType, IntegerType, StringType, StructField, StructType


def get_orders_schema() -> StructType:
    """Schema for the raw orders CSVs landing in the raw volume."""
    return StructType(
        [
            StructField("order_id", IntegerType(), True),
            StructField("customer_id", IntegerType(), True),
            StructField("order_date", DateType(), True),
            StructField("region", StringType(), True),
            StructField("category", StringType(), True),
            StructField("amount", DoubleType(), True),
        ]
    )


def normalize_region(col_name: str) -> Column:
    """Collapses free-text region variants into a fixed set of labels."""
    return (
        when(col(col_name).isin("US", "USA", "United States"), "NA")
        .when(col(col_name).isin("UK", "United Kingdom", "GB"), "EMEA")
        .when(col(col_name).isin("EU", "Europe"), "EMEA")
        .otherwise("Other")
    )


def order_value_band(col_name: str) -> Column:
    """Buckets an order amount into a coarse value band for reporting."""
    return (
        when(col(col_name) < 50, "small")
        .when(col(col_name) < 200, "medium")
        .when(col(col_name) >= 200, "large")
        .otherwise("unknown")
    )
