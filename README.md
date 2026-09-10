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

### Design decisions (the *why* behind the *what*)

**Why three targets (`dev`/`staging`/`prod`), not one.** A `databricks.yml` with a single
target only ever gets tested by whoever's laptop deployed it last. Three targets forces every
variable that differs between environments — catalog, schema path, notification email — to be
declared explicitly instead of hardcoded, which is what actually makes a deploy to prod safe:
the *shape* of what gets deployed is identical to what already ran in staging, only the
target-specific variables differ.

**Why `mode: development` for `dev`/`staging` but `mode: production` for `prod`.** Development
mode does three things: it prefixes every deployed resource name with `[dev <identity>]`
(so ten people's dev deployments in one workspace never collide), it pauses job
schedules/triggers by default (so a dev deploy never fires on a real cron), and it scopes the
deploy to whoever ran it (see `run_as` note below). None of that is appropriate for prod — a
production job needs a stable name, an active schedule, and to run as a fixed identity
regardless of who happened to push the deploying commit. That's what `mode: production` turns
off.

**Why `run_as: service_principal_name` is set explicitly on `prod` but not on `staging`.**
In development mode, the deploy always runs as whoever deployed it — setting `run_as` there
would be ignored. In production mode, without an explicit `run_as`, the job would run as
whichever human or service principal happens to deploy it that day, which is exactly the kind
of implicit, person-dependent behavior a "senior data engineer" repo shouldn't demonstrate.
Pinning it to a service principal means the job's identity is a property of the *bundle*, not
of whoever last ran `git push`.

**Why serverless compute, not a classic cluster.** No cluster to size, configure, or leave
running (and billing) by accident — the pipeline and every job task request compute on demand
and release it when done. The tradeoff, documented at length in Troubleshooting below, is that
serverless's Spark Connect model and its own file-sync quirks are less forgiving of code
patterns that assume a classic local Spark session or notebook semantics.

**Why the job chains `unit_tests → run_pipeline → publish_report`, in that order, with hard
dependencies.** Running the pipeline against bad transform logic wastes real compute and can
leave partially-written tables behind; failing fast in `unit_tests` (pure Python, no data
touched) costs seconds, not minutes. `publish_report` depends on `run_pipeline` for the same
reason in reverse — there's no point reading a gold table that a failed pipeline never
finished writing. `run_if: ALL_SUCCESS` (the default) on each task is what turns "depends_on"
into an actual gate rather than just a display order.

**Why there are two layers of tests, not one.** `tests/unit_tests/` (pytest, local Spark
session, no workspace needed) catches logic bugs in `src/helpers/transform_functions.py`
before anything touches a workspace — fast, free, runs in GitHub Actions on every push.
`src/pipelines/integration_tests.py` (Lakeflow expectations, runs *inside* the deployed
pipeline) catches a different class of bug: things that are only wrong once real data flows
through — a schema mismatch in the actual CSV, an Auto Loader path pointing at the wrong
volume, an expectation that's too strict for the real data's shape. Unit tests can't catch
that category at all, since nothing in them touches a real table.

**Why Auto Loader + expectations for bronze, not a plain batch read.** `cloudFiles` (Auto
Loader) tracks which files it's already ingested, so re-running the pipeline doesn't
re-process the whole volume — the same pattern a real production ingestion job needs, not a
toy `spark.read.csv()` that reads everything every time. `@dp.expect_all_or_drop` on bronze
means a malformed row gets silently dropped and counted, rather than either crashing the whole
run or (worse) silently corrupting silver — the middle ground a real pipeline needs.

## Stack

Databricks Asset Bundles · Lakeflow Declarative Pipelines (SDP) · Unity Catalog · Terraform ·
GitHub Actions · pytest

## Repository layout

```
databricks.yml                        Bundle entry point: targets (dev/staging/prod),
                                       per-target variables, run_as for prod. Start here.
resources/
  variables.yml                       Variable declarations + defaults (catalog, schema,
                                       raw_data_path, notification_email). Per-target
                                       overrides live in databricks.yml, not here.
  job/etl_workflow.job.yml            The job: unit_tests -> run_pipeline -> publish_report,
                                       with hard depends_on/run_if gates between each.
  pipeline/example_etl_pipeline.pipeline.yml
                                       The Lakeflow pipeline: which files are its libraries,
                                       which catalog/schema/volume it targets, root_path.
src/
  helpers/transform_functions.py      Pure functions (schema, region/band mapping) — no
                                       pipeline decorators, no Databricks-only globals. This
                                       is what tests/unit_tests/ actually exercises.
  pipelines/ingest_bronze_silver.py   Bronze (Auto Loader + expectations) and silver
                                       (transform) table definitions. Plain .py, not a
                                       notebook — see Troubleshooting for why that matters.
  pipelines/gold_tables.sql           Gold materialized view, aggregated from silver.
  pipelines/integration_tests.py      Runs *inside* the pipeline; asserts on the real tables
                                       a run produced. Also plain .py, same reason.
  reporting/summary_report.py         Job notebook task; a stand-in for whatever actually
                                       consumes the gold table downstream in a real project.
tests/unit_tests/test_transform_functions.py
                                       pytest against transform_functions.py — local Spark
                                       session, no workspace needed, runs in GitHub Actions.
run_unit_tests.py                     Job notebook task that runs the above suite *inside*
                                       the workspace, gating the pipeline on it.
sample_data/orders_sample.csv         20 rows, uploaded to each environment's `raw` volume
                                       during Getting Started — what Auto Loader reads.
.github/workflows/ci-cd.yml           lint+test on every push; stg -> deploy-staging,
                                       main -> deploy-production (+ auto-run), both gated
                                       behind the test job.
ruff.toml, pytest.ini, requirements-dev.txt
                                       Lint/test config — see Troubleshooting for the
                                       Databricks-specific ruff quirks (builtins, per-file
                                       E402 ignore for run_unit_tests.py).
```

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

### Two ways to do steps 2–6: Terraform or manual

Steps 2–6 below (catalogs, schemas, volumes, service principals, catalog grants, GitHub
environments, the production approval gate) provision the *platform layer* — everything that
has to exist before `databricks bundle deploy` has anywhere to deploy to. There are two ways
to get there, producing the identical end state:

- **Terraform (recommended)** — `cd terraform && cat README.md`, follow that end to end, then
  skip ahead to step 7 (secrets) below. This is what a real team would actually do — Asset
  Bundles are deliberately not meant to provision catalogs or service principals, the same way
  a Kubernetes Deployment isn't meant to provision the cluster it runs on. See the "Design
  decisions" note on this split near the top of this README, and `terraform/README.md` for
  the full rationale on what's Terraform-managed vs. still manual (secrets, by default) and
  why.
- **Manual (steps 2–6 below)** — do this once even if you'll use Terraform for real work
  afterward. Clicking through it yourself is what actually explains *why* each piece exists,
  which `terraform apply` running quietly in a terminal doesn't — the two are equivalent in
  outcome, not in what you learn getting there.

Don't do both against the same workspace — pick one path per environment, since running the
manual steps and then `terraform apply` (or vice versa) against the same catalog/service
principal names will collide (Terraform expects to create resources that don't exist yet, not
adopt ones you made by hand — see "If you already did the manual setup" in
`terraform/README.md` if you want to migrate from one path to the other).

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

**Copy the prod SP's Client ID somewhere you can find it again** — you'll need it in step 10
for `databricks.yml`'s `run_as`, which (despite the field's name) needs this UUID, not the
display name you just typed in.

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

### 9. First real deploy and run (staging)

Push any commit to `stg` to trigger `deploy-staging` in CI, then in Databricks: **Jobs &
Pipelines** → `etl_workflow_staging` → **Run now**. A `[dev <identity>]` prefix on the job name
is expected — `databricks.yml`'s `staging` target uses `mode: development`, and Asset Bundles
always prefix development-mode resources this way regardless of the target's own name. Watch
`unit_tests` → `run_pipeline` → `publish_report` run in sequence.

### 10. Promoting to production

Once staging is clean, merge/push to `main`. A few things are genuinely different about the
production path, not just "same thing, different catalog":

- **It's gated behind manual approval** if you did step 6 — the `deploy-production` job pauses
  in the Actions UI until someone approves it, since `main` also auto-*runs* the job after
  deploying (`databricks bundle run etl_workflow -t prod` — see `ci-cd.yml`), not just uploads
  files like staging does.
- **The job runs as the prod service principal, not whoever deployed it** —
  `databricks.yml`'s `prod` target sets `run_as: service_principal_name: <uuid>` explicitly.
  This is a real, confirmed gotcha: despite the field's name, it needs the service
  principal's **Application ID (a UUID)** from step 3, not its display name — a display name
  passes `databricks bundle validate -t prod` (schema-only check, no API call) but fails the
  *real* `bundle deploy` with `cannot be set as run_as service principal, because it doesn't
  exist`, since only the actual deploy resolves that value against the workspace. Verified by
  hitting exactly this in CI: `bundle validate` was clean locally, then the real deploy failed
  with that error until the value was swapped for the Application ID. Replace the UUID in
  `databricks.yml` with your own prod service principal's Client ID.
- **No `[dev ...]` prefix, and the deploy path is shared, not personal** — `mode: production`
  deploys under `/Workspace/Shared/.bundle/databricks_bundle_template/prod` (see the `prod`
  target's `workspace.root_path`), specifically so production doesn't live under any one
  person's `/Workspace/Users/...` folder. `databricks bundle validate -t prod` will warn that
  this path is writable by every workspace user by default — fine for a single-user Free
  Edition workspace, but in a real multi-user workspace you'd add an explicit `CAN_MANAGE`
  permission block scoped to the deploying service principal (and maybe your platform team),
  per the warning's own suggestion.

Verify the same way as staging: **Jobs & Pipelines** → `etl_workflow_prod` (no `[dev ...]`
prefix this time) → check the most recent run, or trigger one with **Run now**.

### Troubleshooting notes (real errors hit building this template)

These were found by directly inspecting the workspace via the `databricks` CLI — `workspace
list`/`get-status` to check what actually got synced, `pipelines get`/`list-updates`/
`list-pipeline-events` to read the pipeline's real deployed config and error events, `jobs
get-run` for task-level results — rather than relying only on the Databricks UI's error
summaries or an in-workspace assistant's interpretation of them. That distinction mattered in
practice: an early diagnosis (from the workspace's built-in AI assistant) concluded bundle-
deployed files were categorically inaccessible to serverless pipelines, which didn't hold up —
two of the three library files in the same pipeline, deployed the same way, never failed. The
CLI-verified pattern (`databricks workspace list` on the affected directory, across runs) is
what actually found the real, narrower mechanism below. If you hit something similar, prefer
checking the actual API/CLI state over trusting a single plausible-sounding explanation, however
confident it sounds — and note when something you tried *didn't* work, not just what did; a
partial theory that explains 2 of 3 failures usually means the theory is wrong, not that the
third case is "probably the same issue, failing silently."

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
- **Prod deploy fails with `cannot be set as run_as service principal, because it doesn't
  exist`, even though the service principal genuinely exists** — `databricks.yml`'s
  `run_as: service_principal_name` field needs the service principal's **Application ID
  (UUID)**, not its display name, despite the field's name suggesting otherwise. A display
  name passes `databricks bundle validate` (schema-only, no API call) but fails the real
  `bundle deploy`, which does resolve it against the workspace. Use the Client ID shown on
  the service principal's page (Getting Started step 3), not the name you gave it when
  creating it.

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
- The platform layer (catalogs, schemas, service principals, grants, GitHub environments) as
  actual Terraform, not manual clicks written up as if they were infrastructure-as-code — with
  the DABs-vs-Terraform responsibility split made explicit, not blurred

## Where this fits in the portfolio

This repo is the second one built in `modern-data-engineering-lab`, and it's infrastructure
for the rest of the org more than a project in its own right — most of what's here exists to
be forked or copied, not run as-is:

- **[`shared-databricks-utils`](https://github.com/modern-data-engineering-lab/shared-databricks-utils)**
  is its sibling: that repo is the Python utilities every Databricks job imports (logging,
  config, schema validation, retry/backoff); this repo is what deploys the job that imports
  them. Neither is useful alone for a real project — a pipeline needs both shared code *and*
  a deployment story.
- **`finance-lakehouse-platform`** (the portfolio's flagship, planned next after the simpler
  AWS/GCP repos) is meant to fork this repo's `databricks.yml` + `resources/` + `terraform/` +
  `.github/workflows/ci-cd.yml` shape wholesale, then swap `src/pipelines/` for a real
  medallion build and add the governance/CDC/performance layers that repo's scope calls for.
  Every bug fixed here (the `ruff.toml` `builtins` placement, the Spark Connect conflict, the
  notebook-vs-plain-file sync race, the `run_as` UUID gotcha) is a bug that repo now starts
  without, instead of rediscovering independently.
- **`databricks-observability-framework`** and **`streaming-pipeline-kafka-databricks`** are
  both Databricks-deploying repos too, and are expected to follow the same `stg`/`main` branch
  convention, the same environment/secret/service-principal pattern, and the same
  Terraform-for-platform / DABs-for-workload split established here — not because this repo
  mandates it, but because reinventing it per-repo is exactly the wasted effort the "Problem"
  section at the top of this README describes, and because a hiring manager clicking through
  three repos that each do deployment differently reads as inexperience, not variety.
- More generally: **any future Databricks repo in this org should start by reading this one**,
  not by writing a `databricks.yml` from scratch. Fork what applies, deviate deliberately where
  a project's actual requirements differ, and note *why* in that repo's own README when you do
  — the same way this repo's Troubleshooting section explains every deviation from the
  Databricks Academy course material it started from.

## Where this came from

Adapted from the "Full Project" example in Databricks Academy's *Automated Deployment with
Declarative Automation Bundles* course, generalized away from the original lab's domain
dataset and lab-specific cluster lookups, with the GitHub Actions deploy workflow (the course
only lectures on the branch strategy — it doesn't ship the YAML) added on top. See
[`../BUILD-GUIDE.md`](../BUILD-GUIDE.md) for the full source-material inventory behind this
portfolio.
