output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.demo_app.client_id
}

output "secret_name" {
  value = var.secret_name
}
