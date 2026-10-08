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

# Remplace le Contributor sur le cluster : ce rôle ne permet que de lancer
# `az aks command invoke` et d'en lire le résultat. Il ne permet ni de
# modifier le cluster, ni de récupérer un kubeconfig (listClusterUserCredential).
resource "azurerm_role_definition" "aks_command_invoke" {
  name        = "AKS Command Invoke (${var.project_name}-${var.environment})"
  scope       = var.resource_group_id
  description = "Exécution de az aks command invoke uniquement"

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/runcommand/action",
      "Microsoft.ContainerService/managedClusters/commandResults/read",
    ]
    not_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "aks_command_invoke" {
  scope                            = var.aks_cluster_id
  role_definition_id               = azurerm_role_definition.aks_command_invoke.role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}

# --- Cluster : data plane (Kubernetes) --------------------------------------

# Sur un cluster azure_rbac_enabled, command invoke exécute kubectl avec le
# token Entra de l'appelant : sans rôle data plane, le kubectl apply est
# refusé (403) même si le runcommand lui-même passe. Scope limité au
# namespace applicatif — la CI ne peut rien toucher d'autre dans le cluster.
resource "azurerm_role_assignment" "aks_namespace_writer" {
  scope                            = "${var.aks_cluster_id}/namespaces/${var.app_namespace}"
  role_definition_name             = "Azure Kubernetes Service RBAC Writer"
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}

# RBAC Writer ne couvre pas les ressources personnalisées (SecretProviderClass).
# Sans ABAC, ces DataActions couvrent toutes les ressources personnalisées du
# namespace ; aucune permission de suppression ni de gestion des CRD.
resource "azurerm_role_definition" "aks_custom_resources_writer" {
  name        = "AKS Custom Resources Writer (${var.project_name}-${var.environment})"
  scope       = var.resource_group_id
  description = "Lecture et écriture des ressources personnalisées Kubernetes pour la CI"

  permissions {
    actions     = []
    not_actions = []
    data_actions = [
      "Microsoft.ContainerService/managedClusters/customresources/read",
      "Microsoft.ContainerService/managedClusters/customresources/write",
    ]
    not_data_actions = []
  }

  assignable_scopes = [var.resource_group_id]
}

resource "azurerm_role_assignment" "aks_namespace_custom_resources_writer" {
  scope                            = "${var.aks_cluster_id}/namespaces/${var.app_namespace}"
  role_definition_id               = azurerm_role_definition.aks_custom_resources_writer.role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.github.principal_id
  skip_service_principal_aad_check = true
}
