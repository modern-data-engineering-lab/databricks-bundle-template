output "staging_service_principal_application_id" {
  description = "Copy this into ../databricks.yml's staging target if you add an explicit run_as there (prod already needs this — see prod_service_principal_application_id)."
  value       = databricks_service_principal.staging.application_id
}

output "prod_service_principal_application_id" {
  description = "Paste this into ../databricks.yml's prod target under run_as.service_principal_name — it must be the Application ID (UUID), not the display name. See the main README's Troubleshooting notes for why."
  value       = databricks_service_principal.prod.application_id
}

output "staging_service_principal_client_secret" {
  description = "For DATABRICKS_CLIENT_SECRET in the staging GitHub environment, if not using manage_github_secrets_with_terraform."
  value       = databricks_service_principal_secret.staging.secret
  sensitive   = true
}

output "prod_service_principal_client_secret" {
  description = "For DATABRICKS_CLIENT_SECRET in the production GitHub environment, if not using manage_github_secrets_with_terraform."
  value       = databricks_service_principal_secret.prod.secret
  sensitive   = true
}

output "staging_catalog_name" {
  value = databricks_catalog.staging.name
}

output "prod_catalog_name" {
  value = databricks_catalog.prod.name
}

output "staging_raw_volume_path" {
  description = "Where to upload sample_data/orders_sample.csv for staging (Getting Started step 2.4)."
  value       = "/Volumes/${databricks_catalog.staging.name}/${databricks_schema.staging.name}/${databricks_volume.staging_raw.name}"
}

output "prod_raw_volume_path" {
  description = "Where to upload sample_data/orders_sample.csv for prod (Getting Started step 2.4)."
  value       = "/Volumes/${databricks_catalog.prod.name}/${databricks_schema.prod.name}/${databricks_volume.prod_raw.name}"
}
