# ---------------------------------------------------------------------------
# FortiCNAPP integration
#
# One module instance per region. The instance with global = true creates the
# lacework_integration_azure_fortidspm resource, which registers the tenant
# (and subscription) with FortiCNAPP and receives from FortiDSPM one single-use
# activation token and one signed URL to the scan engine image VHD per region.
# Every instance copies its own region's VHD into a storage account in this
# subscription, builds a managed image from it and boots the VM from that
# image; the non-global instances read the token and URL through
# global_module_reference.
# ---------------------------------------------------------------------------
variable "global" {
  description = "Create the FortiCNAPP DSPM integration in this module instance. Exactly one instance per deployment sets this."
  type        = bool
  default     = false
}

variable "global_module_reference" {
  description = "The module instance that has global = true, passed whole (module.<name>). Required when global = false."
  type = object({
    lacework_integration_guid = string
    deployment_id             = string
    deployment_name           = string
    env_id                    = string
    activation_tokens         = map(string)
    image_urls                = map(string)
    hyperv_generations        = map(string)
  })
  default = {
    lacework_integration_guid = ""
    deployment_id             = ""
    deployment_name           = ""
    env_id                    = ""
    activation_tokens         = {}
    image_urls                = {}
    hyperv_generations        = {}
  }
}

variable "tenant_id" {
  description = "Azure tenant the scan engines belong to. Used only by the global instance; empty = the tenant of the current credentials."
  type        = string
  default     = ""
}

variable "subscription_id" {
  description = "Azure subscription the scan engines are deployed in. Used only by the global instance; empty = the subscription of the current credentials (or a tenant-level integration when tenant_level = true)."
  type        = string
  default     = ""
}

variable "regions" {
  description = "Every Azure location a scan engine is deployed in, including this one. Used only by the global instance; FortiDSPM issues one token and image URL per entry."
  type        = list(string)
  default     = []
}

variable "lacework_integration_name" {
  description = "Name of the FortiCNAPP DSPM integration. Used only by the global instance."
  type        = string
  default     = "azure-fortidspm"
}

variable "report_deployment_status" {
  description = "Tell FortiDSPM this location's scan engine was created, with its VM id, private IP and managed identity. Sent only after the VM exists; an apply that fails earlier reports nothing."
  type        = bool
  default     = true
}

variable "image_storage_account_tier" {
  description = "Tier of the storage account that holds the copied image VHD."
  type        = string
  default     = "Standard"
}

# ---------------------------------------------------------------------------
# Per-region inputs — the root passes one region_deployments entry per module
# instance (location + one-time JWT + gallery image version).
# ---------------------------------------------------------------------------

variable "location" {
  description = "Azure region this module instance deploys into (e.g. eastus). Comes from the region_deployments entry; also baked into every resource name so the resource group shows its region."
  type        = string
}






# ---------------------------------------------------------------------------
# Networking
#
# subnet_id: leave empty to have this module create a VNet + subnet; set it to
# reuse an existing subnet in this region (the NSG is attached to the NIC, not
# the subnet, so an existing subnet is never mutated). When auto-creating, the
# *_address_* variables control the address space (identical spaces across
# regions are fine — each region gets its own isolated VNet).
# ---------------------------------------------------------------------------

variable "subnet_id" {
  description = "Existing subnet ID for the scan_engine VM (must be in this module's region). Leave empty to auto-create a VNet + subnet. Must have outbound internet access (scan_engine reaches Fortinet's control plane over HTTPS/WSS on 443)."
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space for the auto-created VNet (only used when subnet_id is empty)."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_address_prefixes" {
  description = "Address prefixes for the auto-created subnet (only used when subnet_id is empty)."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "office_ip" {
  description = "Source IP allowed inbound to TCP 22/443 for debugging (e.g. office egress IP). Leave empty to add no inbound rule (scan_engine needs no inbound for normal operation)."
  type        = string
  default     = ""
}

variable "enable_public_ip" {
  description = "Attach a public IP to the VM (debugging only). scan_engine needs outbound only, so this defaults to false. Set true temporarily if you need inbound access for debugging."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "vm_size" {
  description = "Azure VM size for scan_engine. Recommended at least Standard_D8s_v5 for production scanning; Standard_D4s_v3 is enough for activation smoke tests. ARM sizes (Dps_v5, Epds_v5) do not boot the x86 FortiDSPM image."
  type        = string
  default     = "Standard_D4s_v3"

  validation {
    condition     = can(regex("^Standard_[A-Za-z0-9_]+$", var.vm_size)) && !can(regex("[DdEeFf]p", var.vm_size))
    error_message = "vm_size must be a valid Azure VM size (e.g. Standard_D4s_v3, Standard_D8s_v5, Standard_NC4as_T4_v3). ARM-based sizes (Dps_*, Epds_*, Eps_*) do not boot the x86 FortiDSPM image."
  }
}

variable "zone" {
  description = "Availability zone to pin the VM, its disks and public IP to. Leave EMPTY (default) for regional placement (no zone) so Azure picks any zone with capacity — pinning a single zone often hits 'SkuNotAvailable: Capacity Restrictions'. Set to \"1\"/\"2\"/\"3\" only if you truly need a fixed zone."
  type        = string
  default     = ""
}

variable "data_disk_size_gb" {
  description = "Size in GiB of the data disk the appliance mounts at /var/log (LUKS-encrypted on first boot). Attached inline (storage_data_disk) so it is present at first boot; the appliance refuses to boot without it."
  type        = number
  default     = 300
}

variable "admin_username" {
  description = "VM admin username. Azure requires admin credentials at create time; the patched waagent provision handler bridges these into the FortiData admin login (dlpcode/system/cmd/azure_auth.py)."
  type        = string
  default     = "azureadmin"
}

variable "admin_password" {
  description = <<-EOT
    Password for the VM's admin account.

    azurerm_virtual_machine will not create a Linux VM without a credential
    when disable_password_authentication is false, so this has to exist. Nothing
    ever uses it: the appliance accepts no inbound traffic by default (no public
    IP, and no inbound NSG rule unless office_ip is set), and operators reach it
    through the serial console.

    The default satisfies Azure's rule that a password meet three of lowercase,
    uppercase, digit and special character. A value that meets only two -- say
    "ftnt1234" -- is rejected.
  EOT
  type        = string
  sensitive   = true
  default     = "Ftnt1234!"
}

# ---------------------------------------------------------------------------
# Identity / RBAC
# ---------------------------------------------------------------------------

variable "tenant_level" {
  description = "Tenant-level integration (UI: 'Enable tenant level integration'). When true, scan ALL subscriptions in the tenant — current and future. The identity's roles are granted directly on the DEPLOYMENT subscription (immediate, so the VM has data-plane access at first boot), and a DeployIfNotExists policy assigned at the tenant root management group (tenant_grants.tf) grants the same roles at every OTHER subscription, auto-covering new ones. Roles are NOT assigned at the MG itself: two of them carry DataActions, which don't take effect on the data plane at MG scope (AuthorizationPermissionMismatch). Overrides rbac_scope_id. The identity running terraform must hold Owner (or User Access Administrator + Resource Policy Contributor) at the management group scope. Default false = scan only the deployment subscription."
  type        = bool
  default     = false
}

variable "enable_monitor_audit_logs" {
  description = "Reserved: enable Monitor audit-log (activity/diagnostic) ingestion for this scan_engine. Not yet wired to any resource — currently a no-op placeholder threaded through for a future feature."
  type        = bool
  default     = false
}

variable "rbac_scope_id" {
  description = "Manual scope override for the managed identity's role assignments (Reader + Storage Blob Data Contributor + Log Analytics Reader). Ignored when tenant_level = true. Empty = the deployment subscription; set to a resource group ID to narrow, or a management group ID for a custom scope."
  type        = string
  default     = ""
}

variable "user_assigned_identity_id" {
  description = "Optional resource ID of a pre-created user-assigned managed identity to attach to the VM (e.g. one a customer admin already granted Microsoft Graph permissions to, so no directory privilege is needed at deploy time). Empty = the module creates a user-assigned identity in its resource group (default). The identity is assumed to live in the deployment subscription. Storage/Reader RBAC is still granted to it at deploy time; Graph permissions must be pre-granted by an admin. Give each region its OWN identity — sharing one across regions makes the per-region role assignments collide (RoleAssignmentExists)."
  type        = string
  default     = ""
}

variable "extra_tags" {
  description = "Additional tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Audit log (blob diagnostic logs -> Log Analytics)
#
# The connector queries the StorageBlobLogs table in a Log Analytics workspace
# (dlpcode/storage/connector/azure/azure_activity.py). This module always
# creates a workspace as the destination; routing customer storage blob logs
# into it requires a diagnostic setting on each storage account's blob service,
# driven by monitored_storage_account_ids (leave empty to create none).
# ---------------------------------------------------------------------------

variable "monitored_storage_account_ids" {
  description = "Resource IDs of storage accounts whose blob audit logs (StorageRead/Write/Delete) are routed to THIS region's Log Analytics workspace. List each account in at most one region's entry — the diagnostic setting name is fixed, so two regions monitoring the same account would collide. Leave empty to create the workspace without wiring any diagnostic settings."
  type        = list(string)
  default     = []
}

variable "log_analytics_retention_days" {
  description = "Retention in days for the Log Analytics workspace holding blob audit logs."
  type        = number
  default     = 30
}

variable "enable_graph_permissions" {
  description = "Assign Microsoft Graph app roles (User/Group/Application.Read.All) to the scan_engine managed identity (graph_roles.tf). These are required by the product, so this defaults to true and the grant happens in the main apply. The identity running the apply must therefore be a Global Administrator or Privileged Role Administrator (or hold AppRoleAssignment.ReadWrite.All); subscription Owner alone cannot grant Graph app roles. Set to false only to skip the grant (e.g. to deploy with a non-privileged identity and grant later via the runbook script)."
  type        = bool
  default     = true
}