output "flux_configuration_name" {
  value = azurerm_kubernetes_flux_configuration.main.name
}

output "deploy_key_public" {
  description = "À enregistrer comme deploy key en lecture seule sur le dépôt GitHub"
  value       = tls_private_key.flux_deploy_key.public_key_openssh
}
