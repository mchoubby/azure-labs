output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  description = "Nécessaire en Phase 4 pour fédérer Workload Identity avec des Managed Identities applicatives"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "aks_private_fqdn" {
  value = azurerm_kubernetes_cluster.main.private_fqdn
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "aks_nodes_subnet_id" {
  value = azurerm_subnet.aks_nodes.id
}

output "get_credentials_command" {
  description = "Commande à lancer depuis une machine ayant une route réseau vers le cluster privé (VPN, bastion, ou runner CI dans le VNet)"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}
