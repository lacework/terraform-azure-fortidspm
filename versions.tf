# Provider requirements for the scan_engine module.
#
# Only lower bounds are declared. The root module that calls this one owns the
# exact constraints -- CNAPP's generator emits azurerm ">= 3.80, < 4.0" and
# azuread ">= 2.47, < 4.0" -- and an upper bound here would make any future
# root-side move unsatisfiable.
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
      version = ">= 3.80"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47"
    }
  }
}
