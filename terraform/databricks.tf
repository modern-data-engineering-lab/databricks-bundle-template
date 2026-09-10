####################################################
# Catalogs — one per environment, on purpose
####################################################
# On a single Free Edition workspace, the catalog IS the environment boundary (see the main
# README's "Why catalogs instead of separate workspaces"). `force_destroy = true` lets
# `terraform destroy` remove a catalog even after the bundle-deployed pipeline has created
# tables in it — appropriate for a learning/demo repo where clean teardown matters more than
# accidental-deletion protection; drop it for a real production catalog.
resource "databricks_catalog" "staging" {
  name           = var.staging_catalog_name
  comment        = "databricks-bundle-template staging environment — isolated from prod via grants, not workspace."
  force_destroy  = true
  isolation_mode = "OPEN"
}

resource "databricks_catalog" "prod" {
  name           = var.prod_catalog_name
  comment        = "databricks-bundle-template production environment."
  force_destroy  = true
  isolation_mode = "OPEN"
}

####################################################
# Schemas
####################################################
resource "databricks_schema" "staging" {
  catalog_name  = databricks_catalog.staging.name
  name          = var.schema_name
  force_destroy = true
}

resource "databricks_schema" "prod" {
  catalog_name  = databricks_catalog.prod.name
  name          = var.schema_name
  force_destroy = true
}

####################################################
# Volumes — where sample_data/orders_sample.csv gets uploaded (manually, still — Terraform
# provisions the volume, it doesn't upload files into it; that stays a Getting Started step)
####################################################
resource "databricks_volume" "staging_raw" {
  catalog_name = databricks_catalog.staging.name
  schema_name  = databricks_schema.staging.name
  name         = "raw"
  volume_type  = "MANAGED"
}

resource "databricks_volume" "prod_raw" {
  catalog_name = databricks_catalog.prod.name
  schema_name  = databricks_schema.prod.name
  name         = "raw"
  volume_type  = "MANAGED"
}

####################################################
# Service principals — one per environment (see main README "Why two, not one")
####################################################
resource "databricks_service_principal" "staging" {
  display_name = var.staging_service_principal_name
  active       = true
}

resource "databricks_service_principal" "prod" {
  display_name = var.prod_service_principal_name
  active       = true
}

# OAuth secrets for each SP. These values land in Terraform state (see variables.tf's
# manage_github_secrets_with_terraform comment for the same tradeoff, which applies here too)
# — the outputs below are marked sensitive so a plain `terraform output` doesn't print them,
# but state itself still holds them in plaintext unless your backend encrypts at rest. If
# that's not true of your backend, generate these two secrets manually in the Databricks UI
# instead (Getting Started step 3) and remove these two resources.
resource "databricks_service_principal_secret" "staging" {
  service_principal_id = databricks_service_principal.staging.id
}

resource "databricks_service_principal_secret" "prod" {
  service_principal_id = databricks_service_principal.prod.id
}

####################################################
# Catalog grants — the actual isolation boundary. Each SP gets ALL PRIVILEGES on its own
# catalog and NO grant at all on the other one. No grant, not a narrower grant, is what
# enforces the isolation (see main README step 4's note on this).
####################################################
resource "databricks_grants" "staging_catalog" {
  catalog = databricks_catalog.staging.name
  grant {
    principal  = databricks_service_principal.staging.application_id
    privileges = ["ALL_PRIVILEGES"]
  }
}

resource "databricks_grants" "prod_catalog" {
  catalog = databricks_catalog.prod.name
  grant {
    principal  = databricks_service_principal.prod.application_id
    privileges = ["ALL_PRIVILEGES"]
  }
}
