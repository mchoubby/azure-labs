# Phase 1 — Fondations réseau et cluster AKS

## Ce que ce module provisionne
- Un Resource Group + VNet avec 3 subnets (nodes AKS, private endpoints, App Gateway)
- Un cluster AKS **privé**, en **Azure CNI Overlay**, avec **Calico** pour les Network Policies
- Deux node pools : `system` (isolé, taint `CriticalAddonsOnly`) et `user` (autoscaling 1-5)
- **Azure AD Workload Identity** activé (OIDC issuer) — prêt pour la Phase 4
- Azure RBAC natif pour l'autorisation sur le cluster
- Log Analytics Workspace connecté (Container Insights)

## Prérequis
- Azure CLI connecté (`az login`) avec les droits Contributor sur la souscription cible
- Terraform >= 1.7

## Déploiement

```bash
cp terraform.tfvars.example terraform.tfvars
# éditer terraform.tfvars selon ton besoin

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Accéder au cluster

Le cluster est **privé** : l'API server n'a pas d'IP publique. Deux options :

1. **Rapide pour du dev/test** : ajoute ton IP publique dans `authorized_ip_ranges`
   dans `terraform.tfvars`, puis :
   ```bash
   az aks get-credentials --resource-group <rg> --name <cluster> --overwrite-existing
   kubectl get nodes
   ```
2. **Réaliste** : passe par un bastion/jump box déployé dans le VNet, ou une connexion
   VPN point-to-site vers le VNet — c'est ce qui sera mis en place en Phase 3 pour
   que le runner GitHub Actions puisse déployer sans exposer l'API server.

## Points d'architecture à retenir
- **CNI Overlay vs classique** : en overlay, seuls les nodes consomment des IP du VNet ;
  les pods utilisent un CIDR logique (`10.244.0.0/16`) indépendant. C'est le choix par
  défaut recommandé aujourd'hui pour éviter l'épuisement d'IP sur les gros clusters.
- **Séparation system/user node pool** : le pool `system` ne doit jamais recevoir de
  workload applicatif — c'est le taint `CriticalAddonsOnly` qui l'impose.
- **Identité User-Assigned** plutôt que SystemAssigned : permet de garder une trace
  explicite des role assignments accordés au control plane (auditabilité).
- **`oidc_issuer_enabled` + `workload_identity_enabled`** : ne servent à rien seuls,
  mais sont un prérequis bloquant pour fédérer des identités Azure AD avec des
  ServiceAccounts Kubernetes en Phase 4 (remplace définitivement les secrets/clés
  stockés dans des Kubernetes Secrets).

## Prochaine étape (Phase 2)
Migrer le state local vers un backend `azurerm` (Storage Account + state locking),
et découper ce module en sous-modules réutilisables (`network`, `aks`, `acr`).
