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
  description = "Gallery image version the VM was created from."
  value       = var.image_id
}

output "log_analytics_workspace_id" {
  description = "Workspace (customer) ID for blob audit logs. Register this with the connector so it queries StorageBlobLogs here."
  value       = azurerm_log_analytics_workspace.audit.workspace_id
}