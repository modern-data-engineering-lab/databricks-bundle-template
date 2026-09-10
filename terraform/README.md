# Terraform — platform layer for databricks-bundle-template

Provisions everything in the main README's Getting Started steps 2–6 (catalogs, schemas,
volumes, service principals, catalog grants, GitHub environments/branch policies) — the
platform/infrastructure layer that exists *before* `databricks bundle deploy` has anywhere to
deploy to. This is deliberately separate from the bundle itself: Databricks Asset Bundles are
not meant to provision catalogs or service principals, any more than a Kubernetes Deployment
manifest is meant to provision the cluster it runs on. Terraform owns "does the environment
exist"; the bundle owns "what's running in it."

## What this does and doesn't cover

**Does:** catalogs, schemas, volumes, service principals + their OAuth secrets, catalog
grants, GitHub `staging`/`production` environments with branch-restricted deployment policies
and an optional required-reviewer gate on production.

**Doesn't:** uploading `sample_data/orders_sample.csv` into the volumes Terraform creates
(still a manual step — Terraform provisions storage, not its contents), and — by default —
GitHub Actions secrets (`DATABRICKS_HOST`/`CLIENT_ID`/`CLIENT_SECRET`), which stay a manual
`gh secret set` step unless you explicitly opt in via `manage_github_secrets_with_terraform`
(see the tradeoff documented on that variable in `variables.tf`).

## Prerequisites

- Terraform >= 1.5.
- A Databricks CLI profile already authenticated (`databricks auth login --profile <name>`),
  or `DATABRICKS_HOST`/`DATABRICKS_TOKEN` (or client id/secret) exported as env vars.
- A GitHub token with repo admin + environment scope, exported as `GITHUB_TOKEN` — **not**
  the same as being logged into `gh` CLI; the `integrations/github` Terraform provider needs
  its own token. A fine-grained PAT scoped to just this repo, with "Environments" and
  "Administration" write access, is the minimal option.

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your own values, this file is gitignored
export GITHUB_TOKEN=<your-token>

terraform init
terraform plan    # read it before applying — it's creating real resources in a real workspace
terraform apply
```

After apply, two outputs matter immediately:

```bash
terraform output prod_service_principal_application_id
```
Paste this into `../databricks.yml`'s `prod` target under `run_as.service_principal_name` —
it needs the Application ID (a UUID), not the display name, despite the field's name. This is
a real gotcha documented at length in the main README's Troubleshooting section; Terraform
doesn't save you from it, it just makes the correct value one command away instead of a trip
through the Databricks UI.

```bash
terraform output staging_raw_volume_path
terraform output prod_raw_volume_path
```
Upload `../sample_data/orders_sample.csv` to both (Databricks UI, or `databricks fs cp`).

Then set the GitHub secrets (unless you enabled `manage_github_secrets_with_terraform`) per
the main README's Getting Started step 7, and you're at the same starting point that section's
manual walkthrough gets you to — from here, `databricks bundle deploy` works the same either
way.

## If you already did the manual setup

This config assumes a fresh environment — running `terraform apply` against catalogs/service
principals that already exist manually will fail with "already exists" errors, not quietly
adopt them. Two options: delete the manually-created resources first and let Terraform create
fresh ones (cleanest, but you'll need new service principal secrets and to re-set every GitHub
secret and re-point `databricks.yml`'s `run_as`), or bring the existing resources under
Terraform's management with `terraform import` instead, e.g.:

```bash
terraform import databricks_catalog.staging staging_catalog
terraform import databricks_service_principal.prod <existing-application-id>
```
(One `import` per resource in `databricks.tf`/`github.tf` — check each resource's provider
docs for its exact import ID format, which varies by resource type.) `terraform plan`
afterward will show whether Terraform's desired state actually matches what's really there;
resolve any drift before your next `apply`.

## State

No remote backend is configured — state is a local `terraform.tfstate` file (gitignored,
never commit it: it contains the service principal secrets in plaintext once you've applied).
That's a reasonable default for one person provisioning one Free Edition workspace, and an
explicitly wrong one for a team: multiple people applying against the same local state file
will corrupt it, and a plaintext secret-bearing file has no business on a laptop's disk long
term. A real team would point `versions.tf`'s (currently absent) `backend` block at something
shared and encrypted — S3+DynamoDB with SSE, Terraform Cloud, or Databricks-managed storage.

## Destroying

```bash
terraform destroy
```
`force_destroy = true` on the catalogs and schemas means this works even after the
bundle-deployed pipeline has created tables inside them — appropriate for tearing down a demo
environment, not something you'd want on a real production catalog (drop that argument there).
