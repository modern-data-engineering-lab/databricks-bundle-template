# Databricks notebook source
####################################################
# Example downstream consumer of the gold table
####################################################
# Stands in for whatever actually consumes the pipeline's output in a real project — a BI
# extract, a Slack digest, another team's job. Here it just prints the gold table so the
# job's dependency chain (unit_tests -> run_pipeline -> publish_report) has something real
# to depend on.

dbutils.widgets.text("catalog_name", "")
dbutils.widgets.text("schema_name", "")

catalog_name = dbutils.widgets.get("catalog_name")
schema_name = dbutils.widgets.get("schema_name")

summary = spark.table(f"{catalog_name}.{schema_name}.sales_by_region_band")
summary.orderBy("region", "order_value_band").display()
