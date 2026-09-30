data "azurerm_client_config" "current" {}

# Le nom d'un ACR est global à Azure (FQDN <nom>.azurecr.io), alphanumérique,
# 5-50 caractères. Suffixe déterministe dérivé de la souscription plutôt qu'un
# random_string : même nom à chaque plan, pas de provider supplémentaire.
locals {
  acr_name = substr(
    "acr${var.project_name}${var.environment}${substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 6)}",
    0,
    50
  )
}

# SKU Premium obligatoire : c'est le seul qui supporte les Private Endpoints.
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Premium"
  tags                = var.tags

  # Aucun compte admin (user/password partagé) : toute l'auth passe par
  # Entra ID (kubelet → AcrPull, CI → AcrPush).
  admin_enabled = false

  anonymous_pull_enabled = false

  # Compromis Phase 3 : le runner GitHub hébergé n'a aucune route vers le VNet,
  # il doit donc pousser via l'endpoint public. L'exposition reste limitée à
  # l'authentification Entra ID (pas d'admin, pas de pull anonyme). Les nodes,
  # eux, tirent les images via le Private Endpoint (résolution DNS privée).
  # Passer à false dès qu'un runner self-hosted dans le VNet existe.
  public_network_access_enabled = var.public_network_access_enabled

  # Purge des manifests non tagués après 7 jours (Premium uniquement). Les
  # images taguées par SHA de commit par la CI ne sont pas concernées.
  retention_policy_in_days = 7
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-acr-${var.environment}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# Le sous-ressource "registry" crée deux IP privées : l'endpoint registry
# (<nom>.azurecr.io) et l'endpoint data régional (<nom>.francecentral.data.azurecr.io).
# Le dns_zone_group enregistre automatiquement les deux A records.
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${local.acr_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${local.acr_name}"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

# Les nodes tirent les images avec l'identité kubelet — pas d'imagePullSecret.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = var.kubelet_identity_object_id
  skip_service_principal_aad_check = true
}
