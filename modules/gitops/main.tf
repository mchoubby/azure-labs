# GitOps avec Flux v2, installé via l'extension AKS managée (microsoft.flux).
#
# Modèle pull : les contrôleurs Flux tournent dans le cluster et sortent vers
# GitHub par l'outbound du Load Balancer. Aucun flux entrant vers l'API server
# privé, et la CI n'a plus besoin d'accès au cluster pour déployer.

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "flux"
  cluster_id     = var.aks_cluster_id
  extension_type = "microsoft.flux"
}

# Deploy key SSH en lecture seule, propre à ce cluster. Compromis assumé : la
# clé privée est stockée dans le state Terraform (backend azurerm, accès Entra
# uniquement). RSA plutôt qu'Ed25519 : l'API Flux de l'extension attend une
# clé au format PEM, qu'Ed25519 ne fournit pas.
resource "tls_private_key" "flux_deploy_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_kubernetes_flux_configuration" "main" {
  name       = "gitops"
  cluster_id = var.aks_cluster_id
  namespace  = "flux-system"
  scope      = "cluster"

  git_repository {
    url                      = "ssh://git@github.com/${var.github_repository}.git"
    reference_type           = "branch"
    reference_value          = var.git_branch
    ssh_private_key_base64   = base64encode(tls_private_key.flux_deploy_key.private_key_pem)
    ssh_known_hosts_base64   = base64encode(var.github_known_hosts)
    sync_interval_in_seconds = var.sync_interval_in_seconds
  }

  # Socle du namespace (Namespace, NetworkPolicies de base). Prune activé :
  # un objet retiré de Git est supprimé du cluster, y compris le namespace.
  kustomizations {
    name                       = "platform"
    path                       = "./k8s/platform"
    sync_interval_in_seconds   = var.sync_interval_in_seconds
    retry_interval_in_seconds  = 60
    garbage_collection_enabled = true
  }

  # Application, réconciliée seulement une fois le socle prêt. Les valeurs
  # substituées ne sont pas secrètes (noms, IDs) : le secret reste dans Key
  # Vault et n'est lu que par le CSI driver.
  kustomizations {
    name                       = "app"
    path                       = "./k8s/app"
    depends_on                 = ["platform"]
    sync_interval_in_seconds   = var.sync_interval_in_seconds
    retry_interval_in_seconds  = 60
    timeout_in_seconds         = 300
    garbage_collection_enabled = true

    post_build {
      substitute = var.app_substitutions
    }
  }

  depends_on = [azurerm_kubernetes_cluster_extension.flux]

  dynamic "kustomizations" {
    for_each = var.ingress_enabled ? [1] : []
    content {
      name                       = "ingress"
      path                       = "./k8s/ingress"
      depends_on                 = ["platform", "app"]
      sync_interval_in_seconds   = var.sync_interval_in_seconds
      retry_interval_in_seconds  = 60
      timeout_in_seconds         = 600
      garbage_collection_enabled = true
      post_build {
        substitute = var.ingress_substitutions
      }
    }
  }
}
