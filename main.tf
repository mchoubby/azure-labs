data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = var.tags
}

module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment

  vnet_address_space            = var.vnet_address_space
  aks_nodes_subnet_cidr         = var.aks_nodes_subnet_cidr
  private_endpoints_subnet_cidr = var.private_endpoints_subnet_cidr
  appgw_subnet_cidr             = var.appgw_subnet_cidr
  ingress_enabled               = var.ingress_enabled

  tags = var.tags
}

module "aks" {
  source = "./modules/aks"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment

  vnet_id             = module.network.vnet_id
  aks_nodes_subnet_id = module.network.aks_nodes_subnet_id

  kubernetes_version  = var.kubernetes_version
  system_node_count   = var.system_node_count
  system_node_vm_size = var.system_node_vm_size
  user_node_min_count = var.user_node_min_count
  user_node_max_count = var.user_node_max_count
  user_node_vm_size   = var.user_node_vm_size

  admin_object_ids = var.admin_object_ids

  tags = var.tags
}

module "acr" {
  source = "./modules/acr"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment

  vnet_id                     = module.network.vnet_id
  private_endpoints_subnet_id = module.network.private_endpoints_subnet_id
  kubelet_identity_object_id  = module.aks.kubelet_identity_object_id

  public_network_access_enabled = var.acr_public_network_access_enabled

  tags = var.tags
}

module "ci" {
  source = "./modules/ci"

  resource_group_name = azurerm_resource_group.main.name
  resource_group_id   = azurerm_resource_group.main.id
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment

  github_repository     = var.github_repository
  github_repository_ids = var.github_repository_ids
  github_environment    = var.environment

  acr_id         = module.acr.acr_id
  aks_cluster_id = module.aks.cluster_id

  tags = var.tags
}

module "policy" {
  source = "./modules/policy"

  aks_cluster_id   = module.aks.cluster_id
  acr_login_server = module.acr.acr_login_server
  app_namespaces   = [var.app_namespace]
  effect           = var.policy_effect
}

module "key_vault" {
  source = "./modules/key-vault"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment

  vnet_id                     = module.network.vnet_id
  private_endpoints_subnet_id = module.network.private_endpoints_subnet_id
  aks_oidc_issuer_url         = module.aks.oidc_issuer_url
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  app_namespace               = var.app_namespace
  secret_name                 = var.key_vault_secret_name

  tags = var.tags
}

module "gitops" {
  source = "./modules/gitops"

  aks_cluster_id    = module.aks.cluster_id
  github_repository = var.github_repository
  ingress_enabled   = var.ingress_enabled
  ingress_substitutions = var.ingress_enabled ? {
    ALB_CLIENT_ID     = module.ingress[0].controller_client_id
    ALB_ID            = module.ingress[0].alb_id
    ALB_FRONTEND_NAME = module.ingress[0].frontend_name
    ALB_FQDN          = module.ingress[0].frontend_fqdn
    ALB_SUBNET_CIDR   = var.appgw_subnet_cidr
    WAF_POLICY_ID     = module.ingress[0].waf_policy_id
  } : {}

  app_substitutions = {
    KEY_VAULT_NAME              = module.key_vault.key_vault_name
    KEY_VAULT_SECRET_NAME       = module.key_vault.secret_name
    TENANT_ID                   = data.azurerm_client_config.current.tenant_id
    WORKLOAD_IDENTITY_CLIENT_ID = module.key_vault.workload_identity_client_id
  }

  depends_on = [module.ingress]
}

module "ingress" {
  count  = var.ingress_enabled ? 1 : 0
  source = "./modules/ingress"

  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  project_name               = var.project_name
  environment                = var.environment
  subnet_id                  = module.network.appgw_subnet_id
  aks_oidc_issuer_url        = module.aks.oidc_issuer_url
  node_resource_group_id     = module.aks.node_resource_group_id
  log_analytics_workspace_id = module.aks.log_analytics_workspace_id
  tags                       = var.tags
}

module "monitoring" {
  source = "./modules/monitoring"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  project_name        = var.project_name
  environment         = var.environment
  aks_cluster_id      = module.aks.cluster_id
  aks_cluster_name    = module.aks.cluster_name
  admin_object_ids    = var.admin_object_ids
  tags                = var.tags
}
