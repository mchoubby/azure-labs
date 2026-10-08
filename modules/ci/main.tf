# Identité de la CI GitHub Actions.
#
# User-Assigned Managed Identity plutôt qu'une App Registration Entra ID : pas
# de droits Microsoft Graph nécessaires pour la créer, pas de secret possible
# (une managed identity n'accepte que la fédération), cycle de vie lié à la RG.
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-${var.project_name}-github-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Fédération OIDC : Entra ID accepte un token émis par GitHub uniquement si
# son claim "sub" correspond exactement. Le subject par environnement GitHub
# (et non par branche) permet d'ajouter des protection rules côté GitHub
# (reviewers, branches autorisées) sans toucher à Azure.
#
# Format "immutable" du subject (owner@<id>/repo@<id>) : les IDs numériques ne
# changent jamais, contrairement aux noms. Un repo supprimé puis recréé sous le
# même nom (par toi ou par un tiers qui récupère le nom) n'obtient donc pas de
# token. Sans les IDs, retombe sur le format classique owner/repo.
locals {
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]

  github_subject_repo = (
    var.github_repository_ids == null
    ? var.github_repository
    : "${local.github_owner}@${var.github_repository_ids.owner_id}/${local.github_repo}@${var.github_repository_ids.repository_id}"
  )
}

resource "azurerm_federated_identity_credential" "github" {
  name                      = "github-${var.environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${local.github_subject_repo}:environment:${var.github_environment}"
}

# --- Registry ---------------------------------------------------------------

resource "azurerm_role_assignment" "acr_push" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}

# `az acr login --name` résout le login server via ARM : AcrPush seul ne
# donne que le data plane (push/pull), pas la lecture de la ressource.
resource "azurerm_role_assignment" "acr_reader" {
  scope                            = var.acr_id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}

# --- Cluster : control plane (ARM) ------------------------------------------

# Depuis la Phase 5, Flux déploie (modèle pull) : la CI n'a plus aucun droit
# Kubernetes (ni command invoke, ni rôle data plane). Elle lit seulement
# l'état de conformité de la configuration Flux via ARM pour savoir si son
# commit a été appliqué.
resource "azurerm_role_definition" "aks_deploy_status_reader" {
  name        = "AKS GitOps Status Reader (${var.project_name}-${var.environment})"
  scope       = var.resource_group_id
  description = "Lecture du cluster et de l'état des configurations Flux, sans accès Kubernetes"

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.KubernetesConfiguration/fluxConfigurations/read",
    ]
    not_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "aks_deploy_status_reader" {
  scope                            = var.aks_cluster_id
  role_definition_id               = azurerm_role_definition.aks_deploy_status_reader.role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}

# Mise à jour en place de l'ancien rôle "command invoke" plutôt qu'un
# destroy/create (même identifiant Azure, permissions réduites).
moved {
  from = azurerm_role_definition.aks_command_invoke
  to   = azurerm_role_definition.aks_deploy_status_reader
}

moved {
  from = azurerm_role_assignment.aks_command_invoke
  to   = azurerm_role_assignment.aks_deploy_status_reader
}