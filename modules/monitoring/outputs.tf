output "grafana_endpoint" {
  value = azurerm_dashboard_grafana.main.endpoint
}

output "prometheus_query_endpoint" {
  value = azurerm_monitor_workspace.main.query_endpoint
}

output "monitor_workspace_id" {
  value = azurerm_monitor_workspace.main.id
}
