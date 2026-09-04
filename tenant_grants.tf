# ---------------------------------------------------------------------------
# Tenant-wide RBAC via a DeployIfNotExists (DINE) policy (tenant_level only).
#
# When tenant_level = true the scan_engine identity must read blobs across EVERY
# subscription in the tenant. Assigning a DataActions role (Storage Blob Data
# Contributor, Log Analytics Reader) at the tenant root management group does
# NOT work on the data plane: access isn't updated for hours
# (AuthorizationPermissionMismatch), and custom DataActions roles can't be
# assigned at MG scope at all.
#
# Instead a DINE policy assigned at the MG stamps the three role assignments at
# each SUBSCRIPTION's scope (immediate + correct) and auto-covers subscriptions
# created later. The DEPLOYMENT subscription is EXCLUDED here: it already gets
# the direct, synchronous grant in main.tf (so the VM has data-plane access at
# first boot -- see azurerm_virtual_machine.main depends_on -- and to avoid a
# RoleAssignmentExists clash with the direct grant).
#
# Names include local.name so multiple regional module instances (each with its
# own identity) don't collide on one MG policy object. MG policy assignment
# names are capped at 24 chars, so a short md5-derived name is used there.
#
# The apply identity needs Owner (or User Access Administrator + Resource Policy
# Contributor) at the MG -- already required for tenant_level (see variables.tf).
#
# NOTE (existing subscriptions): MG-scope remediation acts on EXISTING compliance
# data (ReEvaluateCompliance is subscription-scope only). On first apply there is
# no compliance data yet, so already-existing subscriptions are picked up on the
# next policy evaluation cycle (~24h) or by re-running the remediation. New
# subscriptions self-onboard on creation. The deployment subscription is always
# covered immediately by the direct grant in main.tf.
# ---------------------------------------------------------------------------

locals {
  role_defs = {
    reader       = "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader
    blob_contrib = "ba92f5b4-2d11-453d-a403-e96b0029c9fe" # Storage Blob Data Contributor
    la_reader    = "73c42c96-874c-492b-b04d-ab87d138a893" # Log Analytics Reader
    uaa          = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9" # User Access Administrator
    contributor  = "b24988ac-6180-42a0-ab88-20f7382dd24c" # Contributor
  }
  rd_prefix       = "/providers/Microsoft.Authorization/roleDefinitions"
  dine_short_name = "se-${substr(md5(local.name), 0, 20)}" # <= 24 chars for MG policy assignment
}

resource "azurerm_policy_definition" "tenant_grants" {
  count               = var.tenant_level ? 1 : 0
  name                = "fortidspm-se-grants-${local.name}"
  policy_type         = "Custom"
  mode                = "All"
  display_name        = "FortiDSPM scan_engine tenant grants (${local.name})"
  description         = "DeployIfNotExists: grant the scan_engine managed identity Reader + Storage Blob Data Contributor + Log Analytics Reader at each subscription (except the deployment subscription, which is granted directly in main.tf)."
  management_group_id = local.tenant_mg_id

  parameters = jsonencode({
    principalId = {
      type     = "String"
      metadata = { displayName = "Scan engine managed identity principalId" }
    }
    excludeSubscriptionId = {
      type     = "String"
      metadata = { displayName = "Deployment subscription id to skip (granted directly)" }
    }
  })

  policy_rule = jsonencode({
    if = { allOf = [
      { field = "type", equals = "Microsoft.Resources/subscriptions" },
      { field = "name", notEquals = "[parameters('excludeSubscriptionId')]" },
    ] }
    then = {
      effect = "deployIfNotExists"
      details = {
        # Roles the policy's managed identity needs to run the deployment AND
        # create the role assignments. Contributor is required for
        # Microsoft.Resources/deployments/write; UAA for roleAssignments/write.
        type              = "Microsoft.Authorization/roleAssignments"
        roleDefinitionIds = ["${local.rd_prefix}/${local.role_defs.uaa}", "${local.rd_prefix}/${local.role_defs.contributor}"]
        existenceScope    = "subscription"
        deploymentScope   = "subscription"
        # Deployment is atomic (all three grants), so checking one is enough.
        existenceCondition = { allOf = [
          { field = "Microsoft.Authorization/roleAssignments/roleDefinitionId", equals = "${local.rd_prefix}/${local.role_defs.blob_contrib}" },
          { field = "Microsoft.Authorization/roleAssignments/principalId", equals = "[parameters('principalId')]" },
        ] }
        deployment = {
          location = var.location
          properties = {
            mode       = "incremental"
            parameters = { principalId = { value = "[parameters('principalId')]" } }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters     = { principalId = { type = "string" } }
              variables      = { roles = [local.role_defs.reader, local.role_defs.blob_contrib, local.role_defs.la_reader] }
              resources = [{
                type       = "Microsoft.Authorization/roleAssignments"
                apiVersion = "2022-04-01"
                copy       = { name = "roleLoop", count = "[length(variables('roles'))]" }
                name       = "[guid(subscription().subscriptionId, parameters('principalId'), variables('roles')[copyIndex()])]"
                properties = {
                  roleDefinitionId = "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('roles')[copyIndex()])]"
                  principalId      = "[parameters('principalId')]"
                  principalType    = "ServicePrincipal"
                }
              }]
            }
          }
        }
      }
    }
  })
}

resource "azurerm_management_group_policy_assignment" "tenant_grants" {
  count                = var.tenant_level ? 1 : 0
  name                 = local.dine_short_name
  display_name         = "FortiDSPM scan_engine tenant grants (${local.name})"
  management_group_id  = local.tenant_mg_id
  policy_definition_id = azurerm_policy_definition.tenant_grants[0].id
  location             = var.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    principalId           = { value = local.mi_principal_id }
    excludeSubscriptionId = { value = data.azurerm_subscription.current.subscription_id }
  })
}

# The policy's managed identity must be able to create ARM deployments and role
# assignments in EVERY subscription -> grant at the MG (covers new subs too).
resource "azurerm_role_assignment" "dine_mi_uaa" {
  count              = var.tenant_level ? 1 : 0
  scope              = local.tenant_mg_id
  role_definition_id = "${local.rd_prefix}/${local.role_defs.uaa}"
  principal_id       = azurerm_management_group_policy_assignment.tenant_grants[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "dine_mi_contributor" {
  count              = var.tenant_level ? 1 : 0
  scope              = local.tenant_mg_id
  role_definition_id = "${local.rd_prefix}/${local.role_defs.contributor}"
  principal_id       = azurerm_management_group_policy_assignment.tenant_grants[0].identity[0].principal_id
}

# Remediate existing subscriptions. See the NOTE above: acts on existing
# compliance data, so first-apply coverage of pre-existing subs may lag until
# the eval cycle; new subs self-onboard.
resource "azurerm_management_group_policy_remediation" "tenant_grants" {
  count                = var.tenant_level ? 1 : 0
  name                 = "rem-${substr(md5(local.name), 0, 18)}"
  management_group_id  = local.tenant_mg_id
  policy_assignment_id = azurerm_management_group_policy_assignment.tenant_grants[0].id

  depends_on = [
    azurerm_role_assignment.dine_mi_uaa,
    azurerm_role_assignment.dine_mi_contributor,
  ]
}
