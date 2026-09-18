terraform {
  required_providers {
    azurerm  = { source = "hashicorp/azurerm", version = ">= 3.80, < 4.0" }
    azuread  = { source = "hashicorp/azuread", version = ">= 2.47, < 4.0" }
    lacework = { source = "lacework/lacework", version = ">= 2.6.0" }
  }
}

# ARM_TENANT_ID / ARM_SUBSCRIPTION_ID / ARM_CLIENT_ID / ARM_CLIENT_SECRET from the environment.
# The azurerm provider is subscription-scoped, so one provider serves every location.
provider "azurerm" {
  features {}
}

provider "azuread" {}

# LW_ACCOUNT / LW_SUBACCOUNT / LW_API_KEY / LW_API_SECRET from the environment.
provider "lacework" {}

# The global instance registers the tenant and subscription with FortiCNAPP once,
# listing every location, and receives one activation token and one image URL per
# location. Each instance copies its own location's VHD and builds its own image.
module "lacework_azure_fortidspm_westus2" {
  source = "git::https://github.com/lacework/terraform-azure-fortidspm.git?ref=v0.2.0"

  global                    = true
  lacework_integration_name = "azure-dspm-multi-region"
  location                  = "westus2"
  regions                   = ["westus2", "eastus"]
}

# Every other location reads its token and image URL from the global instance.
module "lacework_azure_fortidspm_eastus" {
  source = "git::https://github.com/lacework/terraform-azure-fortidspm.git?ref=v0.2.0"

  global_module_reference = module.lacework_azure_fortidspm_westus2
  location                = "eastus"
}

output "lacework_integration_guid" {
  value = module.lacework_azure_fortidspm_westus2.lacework_integration_guid
}

output "deployment_id" {
  value = module.lacework_azure_fortidspm_westus2.deployment_id
}

output "vm_ids" {
  value = {
    westus2 = module.lacework_azure_fortidspm_westus2.vm_id
    eastus  = module.lacework_azure_fortidspm_eastus.vm_id
  }
}
