resource "azurerm_application_load_balancer" "main" {
  name                = "agc-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_application_load_balancer_subnet_association" "main" {
  name                         = "aks"
  application_load_balancer_id = azurerm_application_load_balancer.main.id
  subnet_id                    = var.subnet_id
}

resource "azurerm_application_load_balancer_frontend" "main" {
  name                         = "public"
  application_load_balancer_id = azurerm_application_load_balancer.main.id
}

resource "azurerm_user_assigned_identity" "controller" {
  name                = "id-${var.project_name}-alb-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "controller" {
  name                = "alb-controller"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.controller.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}

resource "azurerm_role_assignment" "configuration" {
  scope                = azurerm_application_load_balancer.main.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.controller.principal_id
}

resource "azurerm_role_assignment" "network" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.controller.principal_id
}

resource "azurerm_role_assignment" "nodes_reader" {
  scope                = var.node_resource_group_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.controller.principal_id
}

resource "azurerm_web_application_firewall_policy" "main" {
  name                = "waf-${var.project_name}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled = true
    mode    = "Prevention"
  }
  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
  }
  # Test benign et deterministe, sans payload offensif.
  custom_rules {
    name      = "BlockDemoValidationHeader"
    priority  = 10
    rule_type = "MatchRule"
    action    = "Block"
    match_conditions {
      match_variables {
        variable_name = "RequestHeaders"
        selector      = "X-Demo-WAF-Test"
      }
      operator     = "Equal"
      match_values = ["block"]
    }
  }
}

resource "azurerm_application_load_balancer_security_policy" "main" {
  name                               = "waf"
  application_load_balancer_id       = azurerm_application_load_balancer.main.id
  location                           = var.location
  web_application_firewall_policy_id = azurerm_web_application_firewall_policy.main.id
}

resource "azurerm_monitor_diagnostic_setting" "main" {
  name                       = "agc-access-and-waf"
  target_resource_id         = azurerm_application_load_balancer.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
