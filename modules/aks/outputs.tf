output "cluster_id" {
  value = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "private_fqdn" {
  value = azurerm_kubernetes_cluster.main.private_fqdn
}

output "kubelet_identity_object_id" {
  description = "Identité utilisée par les nodes — nécessaire en Phase 3 pour donner les droits de pull sur l'ACR"
  value       = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
output "node_resource_group_id" {
  value = azurerm_kubernetes_cluster.main.node_resource_group_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.aks.id
}
