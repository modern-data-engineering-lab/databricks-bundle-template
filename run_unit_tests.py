# Databricks notebook source
####################################################
# Entry point for the job's `unit_tests` task (see resources/job/etl_workflow.job.yml).
# Runs the same suite CI runs on every push — this just gives the job something to gate on
# before it touches the pipeline, so a broken transform fails fast instead of corrupting data.
####################################################

# COMMAND ----------

# MAGIC %pip install pytest==8.3.4
dbutils.library.restartPython()

# COMMAND ----------

import sys

import pytest

sys.dont_write_bytecode = True

retcode = pytest.main(["./tests/unit_tests", "-v", "-p", "no:cacheprovider"])

assert retcode == 0, "Unit tests failed — see the log above for details."
