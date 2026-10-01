# Azure Policy pour AKS : l'add-on (azure_policy_enabled sur le cluster)
# installe Gatekeeper dans le cluster et synchronise les assignments Azure
# Policy en ConstraintTemplates/Constraints OPA. Les définitions sont gérées
# côté Azure (versionnées, conformité remontée dans le portail), on n'écrit
# pas de Rego ici.
#
# Les définitions sont référencées par GUID (stable) via data source : un
# GUID invalide fait échouer le plan au lieu de l'apply.

data "azurerm_policy_set_definition" "pss_baseline" {
  name = "a8640138-9b0a-4a28-b8cb-1666c838647d" # Pod security baseline standards (Linux)
}

data "azurerm_policy_set_definition" "pss_restricted" {
  name = "42b8ef37-b724-4e24-bbc8-7a7708edfe00" # Pod security restricted standards (Linux)
}

data "azurerm_policy_definition" "allowed_images" {
  name = "febd0533-8e55-448f-b837-bd0e06f16469" # Containers should only use allowed images
}

# Baseline sur tout le cluster, hors namespaces système. Les exclusions par
# défaut de l'initiative ne couvrent PAS calico-system/tigera-operator (pods
# privilégiés + hostNetwork) ni aks-command (pods de az aks command invoke) :
# en Deny sans ces exclusions, Calico ne redémarre plus au prochain reboot
# de node et la CI perd son seul chemin vers le cluster privé.
resource "azurerm_resource_policy_assignment" "pss_baseline" {
  name                 = "pss-baseline"
  display_name         = "Pod Security Baseline (cluster)"
  resource_id          = var.aks_cluster_id
  policy_definition_id = data.azurerm_policy_set_definition.pss_baseline.id

  parameters = jsonencode({
    effect             = { value = var.effect }
    excludedNamespaces = { value = var.system_namespaces }
  })
}

# Restricted uniquement sur les namespaces applicatifs. Plus strict que les
# valeurs par défaut de l'initiative : aucune capability autorisée et drop
# ALL obligatoire (le défaut autorise encore NET_RAW, CHOWN, SETUID, etc.).
resource "azurerm_resource_policy_assignment" "pss_restricted" {
  name                 = "pss-restricted-apps"
  display_name         = "Pod Security Restricted (namespaces applicatifs)"
  resource_id          = var.aks_cluster_id
  policy_definition_id = data.azurerm_policy_set_definition.pss_restricted.id

  parameters = jsonencode({
    effect                   = { value = var.effect }
    namespaces               = { value = var.app_namespaces }
    allowedCapabilities      = { value = [] }
    requiredDropCapabilities = { value = ["ALL"] }
  })
}

# Seules les images de l'ACR du projet sont admises dans les namespaces
# applicatifs : bloque docker.io & co. (images non scannées par la CI).
# source = All : évalue aussi les Deployments (pas seulement les Pods), donc
# un kubectl apply avec une mauvaise image échoue directement dans la CI au
# lieu de laisser un ReplicaSet bloqué à 0 pod.
resource "azurerm_resource_policy_assignment" "allowed_images" {
  name                 = "allowed-images-apps"
  display_name         = "Images ACR uniquement (namespaces applicatifs)"
  resource_id          = var.aks_cluster_id
  policy_definition_id = data.azurerm_policy_definition.allowed_images.id

  parameters = jsonencode({
    effect                      = { value = var.effect }
    namespaces                  = { value = var.app_namespaces }
    allowedContainerImagesRegex = { value = "^${replace(var.acr_login_server, ".", "\\.")}/.+$" }
    source                      = { value = "All" }
  })
}
