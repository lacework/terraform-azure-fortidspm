# Declares which providers this module uses, without constraining their
# versions. Terraform warns "Reference to undefined provider" when a root passes
# `providers = { azurerm = azurerm.<alias> }` to a module that never named
# azurerm, and then guesses hashicorp/azurerm — correctly, but on a guess.
#
# No versions here on purpose: the generated root module carries those, so there
# is one place to change them. Terraform intersects the constraints of every
# module, and a block with sources only adds nothing to intersect.
#
# azuread is listed because graph_roles.tf grants the scan engine's managed
# identity Microsoft Graph app roles.
locals {
  # Deterministic name (no random suffix): location so every resource (and the
  # RG) shows its region, deployment_id so two deployments in the same
  # subscription stay apart. Re-deploying the same deployment_id into the same
  # subscription reuses these names, so Azure refuses the duplicate resource
  # group / VM — an intentional guard against double-deploying the same profile.
  #
  # deployment_name is sanitized (lowercase, non-alphanumerics -> "-", trimmed)
  # and capped at 15 chars so names stay within Azure's 64-char limits; the FULL
  # deployment_name / deployment_id go into tags below.
  dep_name_clean = trim(replace(lower(var.deployment_name), "/[^a-z0-9]+/", "-"), "-")
  dep_name_short = trim(substr(local.dep_name_clean, 0, 15), "-")
  dep_id_short   = substr(var.deployment_id, 0, 8)
  name           = "${var.location}-${local.dep_name_short}-${local.dep_id_short}"

  common_tags = merge({
    "fortidspm:role"            = "scan_engine"
    "fortidspm:managed"         = "terraform"
    "fortidspm:deployment_name" = var.deployment_name
    "fortidspm:deployment_id"   = var.deployment_id
  }, var.env_id != "" ? { "fortidspm:env_id" = var.env_id } : {}, var.extra_tags)

  create_subnet = var.subnet_id == ""
  subnet_id     = local.create_subnet ? azurerm_subnet.main[0].id : var.subnet_id

  # Tenant root management group id (its name == the tenant id). Used by the
  # DINE policy in tenant_grants.tf when tenant_level = true.
  tenant_mg_id = "/providers/Microsoft.Management/managementGroups/${data.azurerm_client_config.current.tenant_id}"

  # Scope for the DIRECT role assignments below -- deliberately NEVER the
  # management group. Two of the three roles carry DataActions (Storage Blob
  # Data Contributor, Log Analytics Reader) and at MG scope the data plane is
  # not updated for hours (AuthorizationPermissionMismatch); custom DataActions
  # roles can't be assigned at MG at all. So the direct grant always lands on a
  # subscription, giving the VM data-plane access at first boot (see
  # azurerm_virtual_machine.main depends_on):
  #   - tenant_level = true  -> the DEPLOYMENT subscription. The OTHER tenant
  #     subscriptions are granted asynchronously by the DINE policy in
  #     tenant_grants.tf (which excludes this deployment subscription).
  #   - tenant_level = false -> rbac_scope_id if set, else this subscription.
  rbac_scope = var.tenant_level ? data.azurerm_subscription.current.id : (var.rbac_scope_id != "" ? var.rbac_scope_id : data.azurerm_subscription.current.id)

  # Managed identity: ALWAYS user-assigned. By default the module creates one
  # (azurerm_user_assigned_identity.main below); user_assigned_identity_id
  # overrides with a pre-created identity (e.g. one a customer admin already
  # granted Microsoft Graph permissions to — see graph_roles.tf / runbook).
  # Because the identity exists before the VM, every grant (ARM RBAC + Graph)
  # completes before first boot — the system-assigned principal used to appear
  # only after VM build, racing RBAC propagation against the appliance's first
  # test_connection/fetch_storage (AuthorizationFailed).
  use_provided_mi   = var.user_assigned_identity_id != ""
  ua_id_parts       = local.use_provided_mi ? split("/", var.user_assigned_identity_id) : []
  ua_name           = local.use_provided_mi ? element(local.ua_id_parts, length(local.ua_id_parts) - 1) : ""
  ua_resource_group = local.use_provided_mi ? local.ua_id_parts[4] : ""

  # Provided path reads the ID back from the data source, not the raw var:
  # the data source normalizes segment casing (e.g. az CLI emits lowercase
  # "resourcegroups", which azurerm_virtual_machine's identity_ids rejects).
  mi_id           = local.use_provided_mi ? one(data.azurerm_user_assigned_identity.provided[*].id) : one(azurerm_user_assigned_identity.main[*].id)
  mi_principal_id = local.use_provided_mi ? one(data.azurerm_user_assigned_identity.provided[*].principal_id) : one(azurerm_user_assigned_identity.main[*].principal_id)
  mi_client_id    = local.use_provided_mi ? one(data.azurerm_user_assigned_identity.provided[*].client_id) : one(azurerm_user_assigned_identity.main[*].client_id)
}

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

# Read the pre-created user-assigned MI (only when one is provided) to get its
# principal_id for the role assignments. Assumed to be in the deployment subscription.
data "azurerm_user_assigned_identity" "provided" {
  count               = var.user_assigned_identity_id != "" ? 1 : 0
  name                = local.ua_name
  resource_group_name = local.ua_resource_group
}

# ---------------------------------------------------------------------------
# Resource group for everything this module creates.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.common_tags
}

# User-assigned managed identity for the VM, created per region unless a
# pre-created one is provided via user_assigned_identity_id. Created before
# the VM so all role assignments complete before first boot (see locals).
resource "azurerm_user_assigned_identity" "main" {
  count               = var.user_assigned_identity_id == "" ? 1 : 0
  name                = "id-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# Networking (VNet/subnet only created when subnet_id is empty).
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  count               = local.create_subnet ? 1 : 0
  name                = "vnet-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "main" {
  count                = local.create_subnet ? 1 : 0
  name                 = "snet-${local.name}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = var.subnet_address_prefixes
}

# ---------------------------------------------------------------------------
# NSG: outbound all, inbound only the office IP (debug). Associated to the NIC
# so an externally-provided subnet is never mutated. scan_engine initiates
# HTTPS/WSS to Fortinet's control plane and to customer storage; it accepts no
# inbound connections in normal operation.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "main" {
  name                = "nsg-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  dynamic "security_rule" {
    for_each = var.office_ip != "" ? [1] : []
    content {
      name                       = "allow-ssh-https-from-office"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = ["22", "443"]
      source_address_prefix      = var.office_ip
      destination_address_prefix = "*"
    }
  }

  # Outbound is allowed by Azure's default rules; explicit for clarity.
  security_rule {
    name                       = "allow-all-outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "main" {
  count               = var.enable_public_ip ? 1 : 0
  name                = "pip-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zone != "" ? [var.zone] : null
  tags                = local.common_tags
}

resource "azurerm_network_interface" "main" {
  name                = "nic-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.enable_public_ip ? azurerm_public_ip.main[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_managed_disk" "data" {
  name                 = "disk-${local.name}-data"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  zone                 = var.zone != "" ? var.zone : null
  tags                 = local.common_tags
}

# ---------------------------------------------------------------------------
# VM running the scan_engine appliance.
#
# Uses the legacy azurerm_virtual_machine (NOT azurerm_linux_virtual_machine)
# on purpose: legacy supports the inline storage_data_disk block, so the data
# disk is attached in the same ARM call and is present at the appliance's FIRST
# boot. With the modern resource the data disk can only be attached via a
# separate azurerm_virtual_machine_data_disk_attachment, which races first boot
# and makes fdtinit.sh fall into the in-memory path. (Verified.)
#
# activation_token is delivered via os_profile.custom_data. The legacy resource
# base64-encodes custom_data internally, so we pass the RAW JWT here (NOT
# base64encode()). Azure delivers it as customData; waagent
# (Provisioning.DecodeCustomData=n) writes the still-base64 value to
# /var/lib/waagent/CustomData; azure_init.py base64-decodes it back to the JWT.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_machine" "main" {
  # All grants (ARM RBAC + Graph app roles) must exist before the VM is
  # created: the appliance calls test_connection/fetch_storage at first boot
  # and previously hit AuthorizationFailed racing RBAC propagation. VM build
  # time (~minutes) absorbs the remaining propagation delay. The graph entry
  # is a no-op when enable_graph_permissions = false (empty for_each); when
  # enabled, an applier without directory privilege now fails BEFORE the VM
  # is built (activation token not consumed) instead of after.
  depends_on = [
    azurerm_role_assignment.reader,
    azurerm_role_assignment.blob_contributor,
    azurerm_role_assignment.log_analytics_reader,
    azuread_app_role_assignment.graph,
  ]

  name                             = "vm-${local.name}"
  resource_group_name              = azurerm_resource_group.main.name
  location                         = azurerm_resource_group.main.location
  vm_size                          = var.vm_size
  zones                            = var.zone != "" ? [var.zone] : null
  network_interface_ids            = [azurerm_network_interface.main.id]
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = false

  storage_image_reference {
    id = var.image_id
  }

  storage_os_disk {
    name              = "osdisk-${local.name}"
    caching           = "None"
    create_option     = "FromImage"
    managed_disk_type = "StandardSSD_LRS"
  }

  # Inline data disk -> present at first boot (see header comment).
  storage_data_disk {
    name            = azurerm_managed_disk.data.name
    managed_disk_id = azurerm_managed_disk.data.id
    create_option   = "Attach"
    lun             = 0
    disk_size_gb    = var.data_disk_size_gb
    caching         = "None"
  }

  os_profile {
    computer_name  = "vm-${local.name}"
    admin_username = var.admin_username
    admin_password = var.admin_password
    custom_data    = var.activation_token # raw JWT; provider base64-encodes
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  # Exactly ONE identity must be attached: the appliance's connector uses a
  # bare DefaultAzureCredential() (no managed_identity_client_id), and IMDS
  # only auto-resolves the identity when a single one is present.
  identity {
    type         = "UserAssigned"
    identity_ids = [local.mi_id]
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = "" # managed boot-diagnostics storage
  }

  tags = local.common_tags

  # Password / custom_data are not returned by the API; ignore so plans stay
  # clean. NOTE: rotating activation_token therefore won't auto-replace the VM
  # — `terraform taint azurerm_virtual_machine.main` (or temporarily remove
  # this ignore) when a fresh token must be re-seeded.
  lifecycle {
    ignore_changes = [os_profile]
  }
}

# ---------------------------------------------------------------------------
# RBAC for the scan_engine managed identity. Roles map to what the Azure
# connector (dlpcode/storage/connector/azure) actually calls:
#   - Reader: list storage accounts (StorageManagementClient), read the
#     activity log (MonitorManagementClient, Microsoft.Storage +
#     Microsoft.Authorization), read roleAssignments (AuthorizationManagementClient).
#   - Storage Blob Data Contributor: read + copy + quarantine + delete blobs
#     and create containers (azure_file_ops: download/upload/upload_from_url/
#     delete_blob/create_container; azure_recycle undelete). Read-only is NOT
#     enough — remediation writes and deletes.
#   - Log Analytics Reader: query StorageBlobLogs in the blob-audit workspace
#     (azure_activity LogsQueryClient.query_workspace). Plain Reader does not
#     grant the Log Analytics data-query action.
#
# NOT covered here (separate from ARM RBAC): the connector also calls Microsoft
# Graph (azure_container_permission: /users /groups /servicePrincipals) to
# resolve identities. That needs Graph application permissions (User.Read.All,
# Group.Read.All, Application.Read.All) granted to this managed identity via
# azuread_app_role_assignment + admin consent — requires the azuread provider
# and directory-level privilege, so it is handled out of this module.
# ---------------------------------------------------------------------------
# The three grants below target local.rbac_scope, which is always a SUBSCRIPTION
# (never the management group -- see the rbac_scope local for why). When
# tenant_level = true they cover the DEPLOYMENT subscription only; the rest of
# the tenant is covered asynchronously by the DINE policy in tenant_grants.tf.
resource "azurerm_role_assignment" "reader" {
  scope                = local.rbac_scope
  role_definition_name = "Reader"
  principal_id         = local.mi_principal_id
}

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = local.rbac_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.mi_principal_id
}

resource "azurerm_role_assignment" "log_analytics_reader" {
  scope                = local.rbac_scope
  role_definition_name = "Log Analytics Reader"
  principal_id         = local.mi_principal_id
}

# Microsoft Graph application permissions for the managed identity are NOT here:
# they require directory privilege (Global Admin / Privileged Role Administrator)
# to assign, not just subscription Owner. See graph_roles.tf (gated by
# enable_graph_permissions, default on) and the runbook.

# ---------------------------------------------------------------------------
# Log Analytics workspace + diagnostic settings for blob audit logs.
# azure_activity.py queries the StorageBlobLogs table in a Log Analytics
# workspace. This module always creates the workspace (the connector's query
# destination); each storage account in monitored_storage_account_ids gets a
# diagnostic setting on its blob service routing StorageRead/Write/Delete here.
# Register this workspace's ID with the connector so it knows where to query.
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "audit" {
  name                = "law-${local.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.common_tags
}

resource "azurerm_monitor_diagnostic_setting" "blob_audit" {
  for_each                   = toset(var.monitored_storage_account_ids)
  name                       = "fortidspm-blob-audit"
  target_resource_id         = "${each.value}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.audit.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}