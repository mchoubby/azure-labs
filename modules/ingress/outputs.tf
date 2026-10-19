output "alb_id" {
  value = azurerm_application_load_balancer.main.id
}
output "frontend_name" {
  value = azurerm_application_load_balancer_frontend.main.name
}
output "frontend_fqdn" {
  value = azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name
}
output "controller_client_id" {
  value = azurerm_user_assigned_identity.controller.client_id
}
output "waf_policy_id" {
  value = azurerm_web_application_firewall_policy.main.id
}
