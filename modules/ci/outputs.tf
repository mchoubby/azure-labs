output "client_id" {
  description = "À renseigner dans la variable GitHub AZURE_CLIENT_ID"
  value       = azurerm_user_assigned_identity.github.client_id
}

output "principal_id" {
  value = azurerm_user_assigned_identity.github.principal_id
}
