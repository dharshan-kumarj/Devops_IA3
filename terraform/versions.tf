# Pinned so that a `terraform apply` run months from now resolves the same
# provider. `~> 4.0` accepts patch and minor updates within major version 4,
# which is where azurerm's resource schemas below are stable.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  # Which subscription to bill and create resources in. Supplied from
  # terraform.tfvars; never hard-coded here, because that file is git-ignored.
  subscription_id = var.subscription_id
}
