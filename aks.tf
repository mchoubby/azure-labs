# Identité managée dédiée au control plane du cluster.
# On utilise une identité User-Assigned plutôt que SystemAssigned pour garder
# un contrôle explicite sur les role assignments (nécessaire en environnement
# où les permissions sont auditées/restreintes).
resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-${var.project_name}-aks-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# Permission pour que le cluster puisse gérer les ressources réseau
# (LB, NSG rules dynamiques) dans le subnet des nodes.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

resource "azurerm_log_analytics_workspace" "aks" {
  name                = "log-${var.project_name}-aks-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${var.project_name}-${var.environment}"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # Cluster privé : l'API server n'a pas d'IP publique.
  # L'accès se fait via VPN/ExpressRoute/bastion, ou depuis un runner CI
  # qui a une route réseau vers le VNet (cf. Phase 3).
  private_cluster_enabled = true

  # Nécessaire pour activer Azure AD Workload Identity juste après.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  # Node pool "system" : héberge uniquement les workloads critiques du
  # control plane (CoreDNS, metrics-server...). On l'isole avec un taint
  # CriticalAddonsOnly pour empêcher les workloads applicatifs d'y atterrir.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = azurerm_subnet.aks_nodes.id
    only_critical_addons_enabled = true
    zones                        = ["1", "2", "3"]

    upgrade_settings {
      max_surge = "10%"
    }
  }

  # Azure CNI en mode Overlay : les pods reçoivent des IP d'un espace
  # d'adressage logique séparé du VNet (pas de consommation d'IP du subnet),
  # ce qui règle le problème classique d'épuisement d'IP sur les gros clusters.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    pod_cidr            = "10.244.0.0/16"
    load_balancer_sku   = "standard"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count, # géré par le cluster autoscaler sur ce pool en phase ultérieure
    ]
  }
}

# Avec azure_rbac_enabled, les rôles Azure du plan de contrôle (Owner, Contributor)
# ne donnent aucun droit sur les objets Kubernetes : il faut un rôle du plan de données.
resource "azurerm_role_assignment" "aks_rbac_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Node pool "user" : héberge les workloads applicatifs, avec autoscaling.
# Séparé du pool system pour pouvoir scaler/redémarrer sans jamais toucher
# aux composants critiques du cluster.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks_nodes.id
  mode                  = "User"
  zones                 = ["1", "2", "3"]

  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}
