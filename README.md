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
| `azurerm_resource_group`, `azurerm_virtual_network`, `azurerm_subnet` | Isolated network |
| `azurerm_network_security_group` | Egress only; nothing is allowed in |
| `azurerm_user_assigned_identity` + role assignments | Read access the scanner needs |
| `azuread_app_role_assignment` (`graph_roles.tf`) | Microsoft Graph app roles for the identity |
| Tenant-wide grants (`tenant_grants.tf`) | Optional, for tenant-level deployments |
| `azurerm_linux_virtual_machine` | The scan engine appliance itself |

## Usage

The module takes the location from the provider passed to it and **declares no
provider of its own**. Instantiate it once per location with an aliased
provider, and one `terraform apply` covers every location in a single state.

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 3.80, < 4.0" }
    azuread = { source = "hashicorp/azuread", version = ">= 2.47, < 4.0" }
  }
}

provider "azurerm" {
  alias = "westus2"
  features {}
}

module "scan_engine_westus2" {
  source = "github.com/lacework/terraform-azure-fortidspm?ref=v0.1.0"

  providers = { azurerm = azurerm.westus2 }

  activation_token = var.activation_token_westus2  # from FortiDSPM, per location
  image_id         = var.image_id_westus2          # from FortiDSPM, per location
  location         = "westus2"

  deployment_id   = "d-1a2b3c4d"
  deployment_name = "azure-dspm-00000000-0000-0000-0000-000000000000"
}
```

`activation_token` and `image_id` are **per location** and are issued by
FortiDSPM when the deployment is created.

`azuread` needs no provider block: it reads the `ARM_*` environment variables
the caller already exports.

## Inputs

Required:

| Name | Description |
|---|---|
| `activation_token` | One-time JWT signed by FortiDSPM's control service, **specific to this location**. Delivered to the appliance through custom data and consumed on first boot. |
| `image_id` | Appliance image for this location. |
| `location` | The Azure location this VM deploys into. |
| `deployment_id` | Identifies the deployment. Takes part in resource naming. |
| `deployment_name` | Human-readable name, applied as a tag. |

Optional, with defaults: `admin_password`, `env_id`, `subnet_id`, `vnet_address_space`,
`subnet_address_prefixes`, `office_ip`, `enable_public_ip`, `vm_size`, `zone`,
`data_disk_size_gb`, `admin_username`, `tenant_level`,
`enable_monitor_audit_logs`, `rbac_scope_id`, `user_assigned_identity_id`,
`extra_tags`, `monitored_storage_account_ids`, `log_analytics_retention_days`,
`enable_graph_permissions`.

See `variables.tf` for the full descriptions and defaults.

## Outputs

`vm_id`, `resource_group_name`, `private_ip`, `public_ip`,
`identity_principal_id`, `identity_client_id`, `identity_id`, `nsg_id`,
`image_id`, `log_analytics_workspace_id`.

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
