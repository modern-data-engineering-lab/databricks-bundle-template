terraform {
  required_version = ">= 1.5.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.30.0, < 2.0.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.0.0, < 7.0.0"
    }
  }

  # No backend block: state is local (terraform.tfstate in this directory, gitignored) by
  # default. Fine for one person provisioning one Free Edition workspace. A real team would
  # point this at a remote backend (S3+DynamoDB, Databricks-managed storage, Terraform
  # Cloud) so state isn't sitting on one laptop — see the "State" section in terraform/README.md.
}
