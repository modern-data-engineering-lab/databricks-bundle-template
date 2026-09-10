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

## Getting Started

This is the full, step-by-step setup this repo was actually built and proven against — a
single **Databricks Free Edition** workspace (one workspace, no separate dev/staging/prod
workspaces) plus a GitHub repo with `gh` CLI access. Every command below is a real command
that was run to get this template working end to end, not a hypothetical. If you have paid
Databricks workspaces per environment, skip the "why one workspace" reasoning and just point
each environment's `DATABRICKS_HOST` at its own workspace instead.

**Why catalogs instead of separate workspaces:** Free Edition gives you exactly one workspace,
not one per environment — that's a hard platform limit, not a choice. Real environment
isolation on one workspace comes from Unity Catalog instead: a `staging_catalog` and
`prod_catalog`, each with its own service principal that can only touch its own catalog. The
bundle's `databricks.yml` is already built around this — the `staging` and `prod` targets
differ only in which catalog they point at, not which host.

### 1. Fork/clone this repo and push it to your own GitHub org

```bash
git clone <your-fork-url>
cd databricks-bundle-template
git checkout -b stg   # see "why two branches" below
git push -u origin main
git push -u origin stg
```

**Why two branches:** the CI/CD workflow (`.github/workflows/ci-cd.yml`) maps `stg` → the
`staging` deploy target and `main` → `prod`. This mirrors the `stg`/`prd` naming convention
used elsewhere in this portfolio's real AWS infra (not the more common `develop`/`main`), so
pick whichever convention your own team already uses and rename consistently in the workflow
file if it differs.

### 2. Databricks: create the catalogs, schemas, and volumes

In the Databricks workspace, open **Catalog** in the left sidebar:

1. **Create Catalog** (top right) → name it `staging_catalog`, type **Standard** (not Foreign,
   Shared, or Lakebase Postgres — Standard is the normal UC catalog backed by cloud storage,
   which is what a bronze/silver/gold pipeline needs). Repeat for `prod_catalog`.
   - These exact names matter: they're already hardcoded as the `catalog` variable defaults
     for the `staging`/`prod` targets in `databricks.yml`, so matching them means zero YAML
     edits. Rename both places together if you'd rather use your own names.
2. Inside each catalog, **Create Schema** → name it `bundle_template` (matches the `schema`
   variable default in `resources/variables.yml`).
3. Inside each `bundle_template` schema, **Create** → **Volume** → name it `raw`, type
   **Managed**. You should end up with `staging_catalog.bundle_template.raw` and
   `prod_catalog.bundle_template.raw` — this is exactly what `raw_data_path` in
   `resources/variables.yml` resolves to per target.
4. Open each volume and **Upload to this volume** → upload `sample_data/orders_sample.csv`
   (or your own CSVs of the same shape) into both. This is what Auto Loader reads from.

### 3. Databricks: create one service principal per environment

Your username (top right) → **Settings** → **Identity and access** → **Service principals** →
**Add service principal**. Create two:

- `sp-databricks-bundle-template-staging`
- `sp-databricks-bundle-template-prod`

For each one, open it and click **Generate secret** — this shows the **Client ID** (also
labeled "Application ID"/"service principal UUID", and permanently visible on the SP's page
afterward) and the **Secret** (shown exactly once, at generation time — copy it immediately).

**Why two, not one:** the whole point of splitting them is that a compromised or misused
staging credential should never be able to touch production data. That guarantee comes from
the catalog grant in the next step, not from the workspace itself (since both SPs live in the
same one workspace here).

**If you accidentally expose a generated secret** (screenshot, chat, commit, anywhere outside
the Databricks UI) — treat it as compromised immediately: open that service principal, delete
the secret, and generate a fresh one. Client IDs aren't sensitive the same way (they're
identifiers, not credentials) and don't need rotating.

### 4. Databricks: grant each service principal its own catalog

Catalog Explorer → `staging_catalog` → **Permissions** tab → **Grant** → add
`sp-databricks-bundle-template-staging` → grant **ALL PRIVILEGES**. Repeat for `prod_catalog`
with the prod service principal. Do **not** grant a staging SP anything on `prod_catalog` or
vice versa — no grant at all is what actually enforces the isolation, regardless of how broad
the privileges are within each SP's own catalog.

(`ALL PRIVILEGES` scoped to one catalog that exists solely for this pipeline is a reasonable
simplification for a project like this — true least-privilege would grant `USE CATALOG` +
`USE SCHEMA` + `CREATE TABLE` + `MODIFY` individually instead, if you want to practice that.)

### 5. GitHub: create the `staging` and `production` environments with `gh` CLI

```bash
REPO=<your-org>/databricks-bundle-template

# Restrict each environment to its own deploy branch
gh api -X PUT repos/$REPO/environments/staging \
  -F "deployment_branch_policy[protected_branches]=false" \
  -F "deployment_branch_policy[custom_branch_policies]=true"
gh api -X POST repos/$REPO/environments/staging/deployment-branch-policies -f name=stg

gh api -X PUT repos/$REPO/environments/production \
  -F "deployment_branch_policy[protected_branches]=false" \
  -F "deployment_branch_policy[custom_branch_policies]=true"
gh api -X POST repos/$REPO/environments/production/deployment-branch-policies -f name=main
```

**Why `-F` and not `-f`:** `-f` sends every value as a string, so GitHub sees `"false"` (text)
instead of `false` (JSON boolean) and rejects the request. `-F` sends typed values. The
`name=stg`/`name=main` calls stay on `-f` since those really are strings.

**What this buys you:** without a branch policy, anyone who can push to *any* branch could
trigger a deploy to `staging` or `production` if they also had the secrets. This makes GitHub
itself refuse a deploy attempt from the wrong branch, before the workflow even runs.

Verify:
```bash
gh api repos/$REPO/environments/staging/deployment-branch-policies -q '.branch_policies[].name'
gh api repos/$REPO/environments/production/deployment-branch-policies -q '.branch_policies[].name'
```

### 6. GitHub: require your approval before a production deploy (optional, recommended)

```bash
MY_ID=$(gh api user -q .id)
gh api -X PUT repos/$REPO/environments/production --input - <<EOF
{
  "reviewers": [ { "type": "User", "id": $MY_ID } ],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
```

This makes a push to `main` pause the `deploy-production` job until you manually approve it in
the Actions UI — a real safeguard for a target that runs `databricks bundle run etl_workflow`
automatically after deploying, not just uploading files.

### 7. GitHub: add the Databricks secrets to each environment

```bash
gh secret set DATABRICKS_HOST --env staging --repo $REPO
gh secret set DATABRICKS_CLIENT_ID --env staging --repo $REPO
gh secret set DATABRICKS_CLIENT_SECRET --env staging --repo $REPO

gh secret set DATABRICKS_HOST --env production --repo $REPO
gh secret set DATABRICKS_CLIENT_ID --env production --repo $REPO
gh secret set DATABRICKS_CLIENT_SECRET --env production --repo $REPO
```

Each command prompts interactively (`? Paste your secret:`) — the wording is generic and
doesn't change based on which value you're setting, so paste the right thing each time:

- `DATABRICKS_HOST` → your workspace URL, e.g. `https://dbc-xxxxxxxx-xxxx.cloud.databricks.com`
  — copy it from the browser address bar and **strip everything after `.com`** (no
  `/browse?o=...` path or query string, no trailing slash). Same value in both environments,
  since it's one workspace.
- `DATABRICKS_CLIENT_ID` → that environment's service principal's Client ID (from step 3).
- `DATABRICKS_CLIENT_SECRET` → that environment's service principal's Secret (from step 3).

After pasting, press Enter then `Ctrl+Z` + Enter on Windows (`Ctrl+D` on macOS/Linux) to submit.

Verify:
```bash
gh secret list --env staging --repo $REPO
gh secret list --env production --repo $REPO
```
Each should list all three names (values are never shown back).

### 8. (Optional) Connect the repo as a Databricks Git folder for interactive dev

This is separate from — and doesn't replace — `databricks bundle deploy`. A Git folder is a
live, editable clone of the repo inside the workspace for browsing/running notebooks
interactively; the bundle deploy is what actually ships a resolved copy to
`.bundle/<name>/<target>/...` for the job/pipeline to run against. Don't point the job at the
Git folder path instead of the bundle-deployed one — that bypasses the whole CI/CD setup here.

Your username → **Settings** → **Linked accounts** → link GitHub, then workspace sidebar →
**Git folders** → **Add repo** → paste this repo's clone URL. Switch branches from the UI's
branch dropdown to browse `stg` vs `main`.

### 9. First real deploy and run

Push any commit to `stg` to trigger `deploy-staging` in CI, then in Databricks: **Jobs &
Pipelines** → `etl_workflow_staging` → **Run now**. A `[dev <identity>]` prefix on the job name
is expected — `databricks.yml`'s `staging` target uses `mode: development`, and Asset Bundles
always prefix development-mode resources this way regardless of the target's own name. Watch
`unit_tests` → `run_pipeline` → `publish_report` run in sequence; once staging is clean, push
to `main` to exercise the same path end-to-end against `prod_catalog`.

### Troubleshooting notes (real errors hit building this template)

- **`ruff` fails with "unknown field `builtins`"** — `builtins` (used to tell ruff that `spark`
  and `dbutils` are injected globals, not undefined names) belongs at the **top level** of
  `ruff.toml`, not nested under `[lint]`. `[lint.flake8-builtins]` is a different, unrelated
  plugin section.
- **Unit tests fail on Databricks with `CANNOT_CONFIGURE_SPARK_CONNECT_MASTER`** — Databricks
  serverless compute (all Free Edition gives you) runs on Spark Connect, which is already
  configured before your code runs. Calling `SparkSession.builder.master("local[2]")`
  unconditionally conflicts with it. Only force a local master when
  `DATABRICKS_RUNTIME_VERSION` isn't in the environment (see the `spark` fixture in
  `tests/unit_tests/test_transform_functions.py`).
- **Pipeline fails at initialization with `LIBRARY_FILE_NOT_FOUND`, and it's a *different*
  library file each run** — confirmed via `databricks workspace list` and the pipeline's own
  event log (`databricks pipelines list-pipeline-events`), not guessed. Two things were tried
  and did **not** fix it: widening the pipeline's `root_path` to cover the file from outside
  its directory, and physically co-locating the file inside `src/pipelines/` alongside the
  other library files. The run kept failing — on `ingest_bronze_silver.py` one run, a
  different file the next — even with every file confirmed to genuinely exist in the
  workspace at the time.
  The actual mechanism: Asset Bundles convert any `.py` file starting with
  `# Databricks notebook source` into a **NOTEBOOK** workspace object on sync (the `.py`
  extension gets stripped from its stored path — confirmed via `databricks workspace list`).
  A plain file with no such header (like a `.sql` library with no notebook markers) skips that
  conversion and is stored as a plain `FILE` instead. Every failure was on a NOTEBOOK-typed
  library; the `.sql` file never once failed. The conversion step appears to have a
  propagation race that a pipeline's library loader can outrun on Free Edition serverless
  compute — a real fetch is issued before the converted notebook is fully visible via the
  Workspace API.
  **Fix:** don't give pipeline library `.py` files a `# Databricks notebook source` header —
  keep them as plain `.py` files (`src/pipelines/ingest_bronze_silver.py` and
  `src/pipelines/integration_tests.py` are written this way now). This only applies to files
  referenced as **pipeline libraries**; a job's own notebook *tasks* (`run_unit_tests.py`,
  `src/reporting/summary_report.py`) use a different, unaffected sync path and can keep the
  notebook header.

## How to run locally

For everyday changes, once the one-time setup above is done:

```bash
# Unit tests run against a local Spark session — no Databricks workspace needed
pip install -r requirements-dev.txt
ruff check .
pytest tests/unit_tests -v

# Deploy/validate against a target (needs `databricks auth login` done once, and the
# catalogs/volumes/service-principal grants from Getting Started already in place)
databricks bundle validate -t staging
databricks bundle deploy -t staging
databricks bundle run etl_workflow -t staging
```

Swap `-t staging` for `-t dev` or `-t prod` as needed — `-t dev` deploys under your own user
identity rather than a service principal, useful for quick iteration without touching CI.

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
