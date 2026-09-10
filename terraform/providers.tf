# Databricks auth: resolved the same way the `databricks` CLI resolves it — env vars
# (DATABRICKS_HOST + DATABRICKS_TOKEN, or DATABRICKS_CLIENT_ID/DATABRICKS_CLIENT_SECRET for
# OAuth M2M) or a named CLI profile (DATABRICKS_CONFIG_PROFILE). Nothing workspace-specific is
# hardcoded here on purpose — this file should work unmodified for anyone forking this repo.
provider "databricks" {
  profile = var.databricks_cli_profile
}

# GitHub auth: the `integrations/github` provider needs its own token — `gh auth login`'s
# token is NOT automatically usable here. Export GITHUB_TOKEN (a classic or fine-grained PAT
# with repo + environment admin scope) before running Terraform — see terraform/README.md.
provider "github" {
  owner = var.github_owner
}
