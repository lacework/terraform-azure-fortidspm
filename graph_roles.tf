# ---------------------------------------------------------------------------
# Microsoft Graph application permissions for the scan_engine managed identity.
#
# The connector resolves user / group / service-principal identities via Graph
# (dlpcode/storage/connector/azure/azure_container_permission.py:
# _fetch_graph_entity_profile -> /v1.0/users|groups|servicePrincipals). These
# app roles are required by the product, so they are granted in the main apply.
#
# PREREQUISITE — WHO CAN RUN THE APPLY:
# Assigning a Graph app role to the VM's managed identity is an admin-consent
# operation, so the identity running the apply must be a Global Administrator or
# Privileged Role Administrator (or hold AppRoleAssignment.ReadWrite.All), NOT
# just subscription Owner. Azure RBAC (ARM resources) and Entra ID directory
# roles are separate systems; subscription Owner cannot grant Graph app roles.
# Enabled by default (enable_graph_permissions = true).
#
# NOTE: the user-assigned identity exists BEFORE the VM (the VM depends_on
# this grant), so an apply run by an identity WITHOUT directory privilege
# fails here BEFORE the VM is built — no partial deployment, and the one-time
# activation token is not consumed. Re-run after fixing privilege is
# idempotent. Set enable_graph_permissions = false to skip the grant and
# instead grant later via azure_shared_gallery_runbook.md (Phase 6) — either
# against the module-created identity (terraform output identity_principal_id)
# or a pre-created one passed via user_assigned_identity_id.
# ---------------------------------------------------------------------------

data "azuread_service_principal" "msgraph" {
  count     = var.enable_graph_permissions ? 1 : 0
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph well-known app ID
}

resource "azuread_app_role_assignment" "graph" {
  for_each = var.enable_graph_permissions ? toset([
    "User.Read.All",
    "Group.Read.All",
    "Application.Read.All",
  ]) : toset([])

  app_role_id         = data.azuread_service_principal.msgraph[0].app_role_ids[each.value]
  principal_object_id = local.mi_principal_id
  resource_object_id  = data.azuread_service_principal.msgraph[0].object_id
}