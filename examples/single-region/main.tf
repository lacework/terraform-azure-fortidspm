terraform {
  required_providers {
    azurerm  = { source = "hashicorp/azurerm", version = ">= 3.80, < 4.0" }
    azuread  = { source = "hashicorp/azuread", version = ">= 2.47, < 4.0" }
    lacework = { source = "lacework/lacework", version = ">= 2.6.0" }
  }
}

# ARM_TENANT_ID / ARM_SUBSCRIPTION_ID / ARM_CLIENT_ID / ARM_CLIENT_SECRET from the environment.
provider "azurerm" {
  features {}
}

provider "azuread" {}

# LW_ACCOUNT / LW_SUBACCOUNT / LW_API_KEY / LW_API_SECRET from the environment.
provider "lacework" {}

# tenant_id / subscription_id default to the ones the azurerm credentials belong to.
module "lacework_azure_fortidspm_westus2" {
  source = "git::https://github.com/lacework/terraform-azure-fortidspm.git?ref=v0.2.0"

  global                    = true
  lacework_integration_name = "azure-dspm-westus2"
  location                  = "westus2"
  regions                   = ["westus2"]
}

output "lacework_integration_guid" {
  value = module.lacework_azure_fortidspm_westus2.lacework_integration_guid
}

output "deployment_id" {
  value = module.lacework_azure_fortidspm_westus2.deployment_id
}

output "vm_id" {
  value = module.lacework_azure_fortidspm_westus2.vm_id
}

output "image_id" {
  description = "Managed image built in this subscription from FortiDSPM's VHD."
  value       = module.lacework_azure_fortidspm_westus2.image_id
}
