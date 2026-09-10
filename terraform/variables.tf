variable "databricks_cli_profile" {
  description = <<-EOT
    Name of a `databricks auth login`-created CLI profile to authenticate as (see
    ~/.databrickscfg). Leave null to fall back to DATABRICKS_HOST/DATABRICKS_TOKEN or
    DATABRICKS_CLIENT_ID/DATABRICKS_CLIENT_SECRET environment variables instead.
  EOT
  type    = string
  default = null
}

variable "github_owner" {
  description = "GitHub org or user that owns the repo (e.g. \"modern-data-engineering-lab\")."
  type        = string
}

variable "github_repository" {
  description = "Repository name only, no owner prefix (e.g. \"databricks-bundle-template\")."
  type        = string
}

variable "staging_catalog_name" {
  description = <<-EOT
    Must match the `catalog` variable default for the `staging` target in ../databricks.yml —
    changing one without the other breaks the bundle deploy.
  EOT
  type    = string
  default = "staging_catalog"
}

variable "prod_catalog_name" {
  description = "Must match the `catalog` variable default for the `prod` target in ../databricks.yml."
  type        = string
  default     = "prod_catalog"
}

variable "schema_name" {
  description = "Must match the `schema` variable default in ../resources/variables.yml."
  type        = string
  default     = "bundle_template"
}

variable "staging_service_principal_name" {
  description = "Display name for the staging service principal."
  type        = string
  default     = "sp-databricks-bundle-template-staging"
}

variable "prod_service_principal_name" {
  description = "Display name for the prod service principal."
  type        = string
  default     = "sp-databricks-bundle-template-prod"
}

variable "production_approver_github_user_id" {
  description = <<-EOT
    Numeric GitHub user ID (not username — get it with `gh api user -q .id`) required to
    approve a production deploy. Set to null to skip the required-reviewer gate entirely.
  EOT
  type    = number
  default = null
}

variable "databricks_host" {
  description = <<-EOT
    Workspace URL (e.g. "https://dbc-xxxxxxxx-xxxx.cloud.databricks.com", no trailing slash
    or path). Only required if manage_github_secrets_with_terraform is true — it's what gets
    written as the DATABRICKS_HOST secret in both GitHub environments. Not used for
    Terraform's own Databricks auth (see databricks_cli_profile for that).
  EOT
  type    = string
  default = null
}

variable "manage_github_secrets_with_terraform" {
  description = <<-EOT
    If true, Terraform writes DATABRICKS_HOST/CLIENT_ID/CLIENT_SECRET directly into the
    staging/production GitHub environment secrets. Convenient, but means the service
    principal secrets land in Terraform state in plaintext (GitHub's API requires the
    plaintext value to encrypt client-side before upload — Terraform state stores what it
    sent). Safe only if your state backend is itself encrypted and access-controlled (a
    remote backend with encryption at rest, not a local .tfstate file sitting in a repo
    folder). Defaults to false: secrets stay a manual `gh secret set` step (see the main
    README's Getting Started step 7) so state never holds a credential.
  EOT
  type    = bool
  default = false
}
