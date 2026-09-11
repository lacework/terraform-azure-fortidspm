output "vm_id" {
  description = "Resource ID of the scan_engine VM."
  value       = azurerm_virtual_machine.main.id
}

output "resource_group_name" {
  description = "Resource group holding the deployed resources."
  value       = azurerm_resource_group.main.name
}

output "private_ip" {
  description = "Private IP of the scan_engine VM."
  value       = azurerm_network_interface.main.private_ip_address
}

output "public_ip" {
  description = "Public IP of the scan_engine VM (empty when enable_public_ip = false)."
  value       = var.enable_public_ip ? azurerm_public_ip.main[0].ip_address : ""
}

output "identity_principal_id" {
  description = "Principal ID of the user-assigned managed identity attached to the VM."
  value       = local.mi_principal_id
}

output "identity_client_id" {
  description = "Client ID of the VM's user-assigned managed identity (the identity IMDS serves to DefaultAzureCredential)."
  value       = local.mi_client_id
}

output "identity_id" {
  description = "Resource ID of the user-assigned managed identity attached to the VM."
  value       = local.mi_id
}

output "nsg_id" {
  description = "Resource ID of the network security group."
  value       = azurerm_network_security_group.main.id
}

output "image_id" {
  description = "Managed image the VM was created from, built in this subscription from the FortiDSPM VHD."
  value       = azurerm_image.scan_engine.id
}

output "log_analytics_workspace_id" {
  description = "Workspace (customer) ID for blob audit logs. Register this with the connector so it queries StorageBlobLogs here."
  value       = azurerm_log_analytics_workspace.audit.workspace_id
}
output "lacework_integration_guid" {
  description = "GUID of the FortiCNAPP DSPM integration this scan engine belongs to."
  value       = local.integration.lacework_integration_guid
}

output "deployment_id" {
  description = "FortiDSPM deployment id."
  value       = local.integration.deployment_id
}

output "deployment_name" {
  description = "FortiDSPM deployment name."
  value       = local.integration.deployment_name
}

output "env_id" {
  description = "FortiDSPM environment id."
  value       = local.integration.env_id
}

output "activation_tokens" {
  description = "Single-use activation token per location, as issued by FortiDSPM. Read by the non-global module instances."
  value       = local.integration.activation_tokens
  sensitive   = true
}

output "image_urls" {
  description = "Signed scan engine image VHD URL per location, as issued by FortiDSPM."
  value       = local.integration.image_urls
  sensitive   = true
}

output "hyperv_generations" {
  description = "Hyper-V generation of the scan engine image per location."
  value       = local.integration.hyperv_generations
}
