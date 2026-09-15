# Provider requirements for the scan_engine module.
#
# azurerm is pinned below 4.0: the legacy azurerm_virtual_machine (needed for
# the inline data disk) and the storage_account_name arguments this module
# uses are the 3.x shapes, and a generated root declares no constraint of its own.
#
# azuread is required because graph_roles.tf grants the scan engine's managed
# identity Microsoft Graph app roles. It needs no provider block of its own: it
# picks up credentials from the ARM_* environment variables the caller already
# exports.
#
# No `provider` block: the location comes from the provider the root passes in.

terraform {
  required_version = ">= 1.2"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80, < 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47, < 4.0"
    }
    lacework = {
      source  = "lacework/lacework"
      version = ">= 2.6.0" # lacework_integration_*_fortidspm and lacework_fortidspm_deployment_status first shipped in 2.6.0
    }
  }
}
