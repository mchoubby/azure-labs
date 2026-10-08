output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "aks_private_fqdn" {
  value = module.aks.private_fqdn
}

output "vnet_id" {
  value = module.network.vnet_id
}

output "aks_nodes_subnet_id" {
  value = module.network.aks_nodes_subnet_id
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.cluster_name} --overwrite-existing"
}

output "acr_name" {
  value = module.acr.acr_name
}

output "acr_login_server" {
  value = module.acr.acr_login_server
}

output "key_vault_name" {
  value = module.key_vault.key_vault_name
}

output "key_vault_uri" {
  value = module.key_vault.key_vault_uri
}

# Valeurs à reporter dans Settings → Environments → <environment> → Variables
# du dépôt GitHub. Aucune n'est un secret : sans la fédération OIDC côté
# Entra ID, connaître ces IDs ne permet pas d'obtenir un token.
output "github_actions_variables" {
  value = {
    AZURE_CLIENT_ID             = module.ci.client_id
    AZURE_TENANT_ID             = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID       = data.azurerm_client_config.current.subscription_id
    ACR_NAME                    = module.acr.acr_name
    AKS_RESOURCE_GROUP          = azurerm_resource_group.main.name
    AKS_CLUSTER_NAME            = module.aks.cluster_name
    APP_NAMESPACE               = var.app_namespace
    KEY_VAULT_NAME              = module.key_vault.key_vault_name
    KEY_VAULT_SECRET_NAME       = module.key_vault.secret_name
    WORKLOAD_IDENTITY_CLIENT_ID = module.key_vault.workload_identity_client_id
  }
}
