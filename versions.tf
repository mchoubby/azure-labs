terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Phase 2 remplacera ce backend local par un backend "azurerm"
  # pointant vers un Storage Account dédié au state, avec state locking.
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "azuread" {}
