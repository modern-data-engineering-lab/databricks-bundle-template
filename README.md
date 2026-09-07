# databricks-bundle-template

[![CI/CD](https://github.com/modern-data-engineering-lab/databricks-bundle-template/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/modern-data-engineering-lab/databricks-bundle-template/actions/workflows/ci-cd.yml)

A minimal, working Databricks Asset Bundle (DAB) project — dev/staging/prod deploy targets,
a Lakeflow Declarative Pipeline with tests, and a real branch→environment CI/CD workflow —
meant to be forked, not run as-is. It's the Databricks-side counterpart to
[`shared-databricks-utils`](https://github.com/modern-data-engineering-lab/shared-databricks-utils):
that repo is the Python utilities every job imports, this one is the deployment scaffolding
every job is deployed with.

## Problem

Every new Databricks project needs the same handful of deployment decisions made before any
real work starts: how are dev/staging/prod separated, how do variables move between them, how
does CI actually deploy a bundle (not just lint it), and what does a minimal-but-real pipeline
+ job + test layout look like. Answering those from scratch each time is wasted effort — and
skipping them is how projects end up hand-deployed from a laptop indefinitely.

## Architecture

```
                     ┌─────────────────────────────────────────┐
                     │              etl_workflow job            │
                     │                                           │
   push to           │  unit_tests ──▶ run_pipeline ──▶ publish_report
   stg/main          │   (pytest)    (SDP pipeline)    (notebook)
        │             └─────────────────────────────────────────┘
        ▼                              │
  GitHub Actions                       ▼
  ┌──────────┐   deploy -t staging   ┌─────────────────────────────┐
  │   test   │──────────────────────▶│ example_etl_pipeline         │
  │ (lint +  │                       │  orders_bronze (Auto Loader) │
  │  pytest) │   deploy -t prod      │   → orders_silver             │
  └──────────┘──────────────────────▶│    → sales_by_region_band     │
                                      └─────────────────────────────┘
```

`stg` deploys to the `staging` target, `main` deploys to `prod` — both gated behind the
`test` job (lint + unit tests) so nothing broken reaches a real workspace.

## Stack

Databricks Asset Bundles · Lakeflow Declarative Pipelines (SDP) · Unity Catalog · GitHub
Actions · pytest

## How to run locally

Unit tests run against a local Spark session and need no Databricks workspace:

```bash
pip install -r requirements-dev.txt
ruff check .
pytest tests/unit_tests -v
```

To deploy the bundle itself, you need a Databricks workspace and the CLI:

```bash
pip install databricks-cli  # or: curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
databricks auth login --host <your-workspace-url>

# Point resources/variables.yml's raw_data_path at a volume containing sample_data/orders_sample.csv
# (or your own CSVs of the same shape) for the target you're deploying to, then:
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run etl_workflow -t dev
```

Swap `-t dev` for `-t staging` / `-t prod` once the corresponding catalogs exist in your
workspace (see `targets:` in `databricks.yml`) — the `dev_catalog` / `staging_catalog` /
`prod_catalog` defaults are placeholders, not real catalog names.

### CI/CD secrets

`deploy-staging` and `deploy-production` need a GitHub Environment (`staging`, `production`)
with `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, and `DATABRICKS_CLIENT_SECRET` secrets for a
Databricks service principal (OAuth machine-to-machine — no personal access tokens), one
service principal per environment so a compromised staging credential can't touch prod.
Without these configured, the `test` job still runs on every push/PR; only the deploy jobs
need them. `staging`'s environment should restrict deployment to the `stg` branch,
`production`'s to `main` — set under each environment's "Deployment branches and tags" rule
so a feature branch can never accidentally target either.

## What this demonstrates

- A Databricks Asset Bundle structured for real multi-environment deployment, not just a
  single `databricks.yml` with one target
- A working GitHub Actions branch→environment deploy strategy (`stg`→staging,
  `main`→prod) using OAuth service-principal auth — not just a slide describing one
- Transform logic kept separate from the pipeline definition specifically so it's
  unit-testable without a live workspace (`src/helpers/` + `tests/unit_tests/`)
- Pipeline-level integration tests that assert on the real tables a run produced, using
  Lakeflow expectations, not a separate mocking framework
- A deployment scaffold generic enough to fork: swap `src/pipelines/` and
  `resources/*.yml` for your own domain and the dev/staging/prod/CI shape carries over
  unchanged

## Where this came from

Adapted from the "Full Project" example in Databricks Academy's *Automated Deployment with
Declarative Automation Bundles* course, generalized away from the original lab's domain
dataset and lab-specific cluster lookups, with the GitHub Actions deploy workflow (the course
only lectures on the branch strategy — it doesn't ship the YAML) added on top. See
[`../BUILD-GUIDE.md`](../BUILD-GUIDE.md) for the full source-material inventory behind this
portfolio.
