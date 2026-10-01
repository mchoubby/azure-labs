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
  app_namespace  = var.app_namespace

  tags = var.tags
}

module "policy" {
  source = "./modules/policy"

  aks_cluster_id   = module.aks.cluster_id
  acr_login_server = module.acr.acr_login_server
  app_namespaces   = [var.app_namespace]
  effect           = var.policy_effect
}
