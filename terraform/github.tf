####################################################
# GitHub environments — mirrors main README Getting Started steps 5-6, done via Terraform
# instead of `gh api` calls.
####################################################
resource "github_repository_environment" "staging" {
  repository  = var.github_repository
  environment = "staging"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "staging" {
  repository     = var.github_repository
  environment    = github_repository_environment.staging.environment
  branch_pattern = "stg"
}

resource "github_repository_environment" "production" {
  repository  = var.github_repository
  environment = "production"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }

  # Only added when production_approver_github_user_id is set — a production deploy without
  # a required reviewer still deploys automatically on push to main, which is a real (if
  # deliberate) choice, not an oversight, if you leave the variable null.
  dynamic "reviewers" {
    for_each = var.production_approver_github_user_id != null ? [var.production_approver_github_user_id] : []
    content {
      users = [reviewers.value]
    }
  }
}

resource "github_repository_environment_deployment_policy" "production" {
  repository     = var.github_repository
  environment    = github_repository_environment.production.environment
  branch_pattern = "main"
}

####################################################
# GitHub secrets — opt-in only, see variables.tf's manage_github_secrets_with_terraform for
# why this defaults to false. When enabled, these six resources replace the six `gh secret
# set` commands in Getting Started step 7 entirely.
####################################################
resource "github_actions_environment_secret" "staging_host" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.staging.environment
  secret_name     = "DATABRICKS_HOST"
  plaintext_value = var.databricks_host
}

resource "github_actions_environment_secret" "staging_client_id" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.staging.environment
  secret_name     = "DATABRICKS_CLIENT_ID"
  plaintext_value = databricks_service_principal.staging.application_id
}

resource "github_actions_environment_secret" "staging_client_secret" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.staging.environment
  secret_name     = "DATABRICKS_CLIENT_SECRET"
  plaintext_value = databricks_service_principal_secret.staging.secret
}

resource "github_actions_environment_secret" "prod_host" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.production.environment
  secret_name     = "DATABRICKS_HOST"
  plaintext_value = var.databricks_host
}

resource "github_actions_environment_secret" "prod_client_id" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.production.environment
  secret_name     = "DATABRICKS_CLIENT_ID"
  plaintext_value = databricks_service_principal.prod.application_id
}

resource "github_actions_environment_secret" "prod_client_secret" {
  count           = var.manage_github_secrets_with_terraform ? 1 : 0
  repository      = var.github_repository
  environment     = github_repository_environment.production.environment
  secret_name     = "DATABRICKS_CLIENT_SECRET"
  plaintext_value = databricks_service_principal_secret.prod.secret
}
