# terraform-azure-fortidspm

Terraform module that deploys one FortiDSPM **scan engine** into a single Azure
location: a resource group, its networking, a managed identity with the roles
the scanner needs, and the VM appliance.

This module belongs to the **FortiDSPM** architecture, in which the scan engine
pushes results to FortiCNAPP through presigned URLs. It is not related to
[`terraform-azure-dspm`](https://github.com/lacework/terraform-azure-dspm),
which implements the earlier design where results landed in the customer's own
storage account and FortiCNAPP read them back.

## What it creates

| Resource | Purpose |
|---|---|
| `lacework_integration_azure_fortidspm` (global instance only) | Registers the tenant with FortiCNAPP; FortiDSPM issues the per-location activation tokens and image URLs |
| `azurerm_storage_account`, `azurerm_storage_container`, `azurerm_storage_blob`, `azurerm_image` | Server-side copy of the scan engine image VHD into this subscription and the managed image the VM boots from |
| `azurerm_resource_group`, `azurerm_virtual_network`, `azurerm_subnet` | Isolated network |
| `azurerm_network_security_group` | Egress only; nothing is allowed in |
| `azurerm_user_assigned_identity` + role assignments | Read access the scanner needs |
| `azuread_app_role_assignment` (`graph_roles.tf`) | Microsoft Graph app roles for the identity |
| Tenant-wide grants (`tenant_grants.tf`) | Optional, for tenant-level deployments |
| `azurerm_linux_virtual_machine` | The scan engine appliance itself |

## Usage

One module instance per location. Exactly one instance sets `global = true`:
it creates the `lacework_integration_azure_fortidspm` resource, which
registers the tenant and subscription with FortiCNAPP and receives from
FortiDSPM one single-use activation token and one signed URL to the scan
engine image VHD per location. Every instance copies its own location's VHD
into a storage account in this subscription (server-side, no bytes through the
machine running terraform), builds a managed image from it and boots the VM
from that image. The non-global instances take the global one as
`global_module_reference`. One `terraform apply` covers every location.

```hcl
terraform {
  required_providers {
    azurerm  = { source = "hashicorp/azurerm", version = ">= 3.80, < 4.0" }
    azuread  = { source = "hashicorp/azuread", version = ">= 2.47, < 4.0" }
    lacework = { source = "lacework/lacework", version = "~> 2.0" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "11111111-1111-1111-1111-111111111111" # ARM_* credentials from the environment
}

provider "azuread" {}
provider "lacework" {} # LW_ACCOUNT / LW_API_KEY / LW_API_SECRET from the environment

module "lacework_azure_fortidspm_westus2" {
  source = "git::https://github.com/lacework/terraform-azure-fortidspm.git?ref=v0.2.0"

  global                    = true
  lacework_integration_name = "azure-dspm-production"
  tenant_id                 = "00000000-0000-0000-0000-000000000000"
  subscription_id           = "11111111-1111-1111-1111-111111111111"
  regions                   = ["westus2", "eastus"]
  location                  = "westus2"
}

module "lacework_azure_fortidspm_eastus" {
  source = "git::https://github.com/lacework/terraform-azure-fortidspm.git?ref=v0.2.0"

  global_module_reference = module.lacework_azure_fortidspm_westus2
  location                = "eastus"
}
```

The activation token is single-use. Rebuilding a VM needs a new token, which
means a new integration: taint the module's
`lacework_integration_azure_fortidspm` resource and apply again. The image URL
is signed for a limited time and is re-signed on every FortiDSPM call, so the
copied blob ignores later changes to it.

## Inputs

| Name | Description |
|---|---|
| `location` | Azure location this instance deploys into. |
| `global` | Create the FortiCNAPP DSPM integration in this instance. Exactly one instance per deployment. Default `false`. |
| `global_module_reference` | The instance with `global = true`, passed whole (`module.<name>`). Required when `global = false`. |
| `regions` | Every location a scan engine is deployed in, including this one. Global instance only. |
| `lacework_integration_name` | Name of the FortiCNAPP DSPM integration. Global instance only. Default `azure-fortidspm`. |
| `tenant_id` | Azure tenant the scan engines belong to. Empty = tenant of the current credentials. Global instance only. |
| `subscription_id` | Subscription the scan engines are deployed in. Empty = subscription of the current credentials, or a tenant-level integration when `tenant_level = true`. Global instance only. |

Optional, with defaults: `report_deployment_status` (tell FortiDSPM the
location's scan engine is up, default `true`), `subnet_id`, `vnet_address_space`,
`subnet_address_prefixes`, `office_ip`, `enable_public_ip`, `vm_size`, `zone`,
`data_disk_size_gb`, `admin_username`, `admin_password`, `tenant_level`,
`enable_monitor_audit_logs`, `rbac_scope_id`, `user_assigned_identity_id`,
`extra_tags`, `monitored_storage_account_ids`, `log_analytics_retention_days`,
`enable_graph_permissions`, `image_storage_account_tier`.

## Outputs

Per instance: `vm_id`, `resource_group_name`, `private_ip`, `public_ip`,
`identity_principal_id`, `identity_client_id`, `identity_id`, `nsg_id`,
`image_id` (the managed image built here), `log_analytics_workspace_id`.

Shared, read by the non-global instances through `global_module_reference`:
`lacework_integration_guid`, `deployment_id`, `deployment_name`, `env_id`,
`activation_tokens` (sensitive), `image_urls` (sensitive), `hyperv_generations`.

## Notes

**Naming is deterministic — there is no random suffix.** Names combine the
location (so every resource shows its region) with `deployment_id` (which keeps
separate deployments apart). Re-deploying the same `deployment_id` into the same
subscription therefore fails on the duplicate resource group, which is a
deliberate guard against deploying the same profile twice.

**`activation_token` is single-use.** The appliance exchanges it for long-lived
credentials the first time it boots. If the VM is ever rebuilt, ask FortiDSPM
for a fresh token — reusing the spent one leaves the appliance unregistered.

**A rotated token does not replace the VM on its own.** `os_profile` carries
both the password and the token, and the Azure API returns neither, so the
resource ignores changes to it to keep plans clean. When a fresh token has to be
seeded, taint the VM:

```
terraform taint 'module.scan_engine_westus2.azurerm_virtual_machine.main'
```

**`admin_password` exists only because Azure demands one.** The appliance takes
no inbound traffic in the default configuration — no public IP, and no inbound
NSG rule unless `office_ip` is set — and operators reach it through the serial
console. It has a working default; override it if a deployment needs its own.

## License

MIT. See [LICENSE](./LICENSE).
