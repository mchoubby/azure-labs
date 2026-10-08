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

---

# Phase 3 — CI/CD GitHub Actions en OIDC

## Ce qui est ajouté
- `modules/acr` : ACR Premium sans compte admin, Private Endpoint dans
  `snet-private-endpoints`, zone DNS `privatelink.azurecr.io` liée au VNet,
  `AcrPull` pour l'identité kubelet.
- `modules/ci` : identité managée fédérée avec GitHub (aucun secret Azure
  côté GitHub). Droits : `AcrPush` + `Reader` sur l'ACR, rôle custom limité à
  `az aks command invoke` sur le cluster, `AKS RBAC Writer` sur le namespace
  `demo-app` uniquement.
- `.github/workflows/deploy.yml` : build + scan Trivy sans aucun accès Azure,
  puis job `deploy` (environnement GitHub `dev`) : push ACR → `kubectl apply`
  via `az aks command invoke`.

## Mise en place
```bash
# 1. Renseigner github_repository = "<owner>/<repo>" dans terraform.tfvars
terraform plan -out=tfplan && terraform apply tfplan

# 2. Namespace applicatif (une seule fois, en admin — la CI ne peut pas le créer)
az aks command invoke -g <rg> -n <cluster> --file k8s/namespace.yaml \
  --command "kubectl apply -f namespace.yaml"

# 3. Côté GitHub : créer l'environnement "dev" et y reporter les variables
terraform output github_actions_variables
```

---

# Phase 4 — Key Vault, Secrets Store CSI Driver et Workload Identity

## Ce qui est ajouté

- L'add-on AKS **Secrets Store CSI Driver** avec rotation des secrets activée.
- `modules/key-vault` : un Key Vault en mode **Azure RBAC**, sans endpoint
  public, avec soft-delete (90 jours), purge protection, Private Endpoint et
  zone DNS `privatelink.vaultcore.azure.net`.
- Une identité managée dédiée à `demo-app`, fédérée exclusivement au
  ServiceAccount `system:serviceaccount:demo-app:demo-app`.
- Le rôle `Key Vault Secrets User`, limité au coffre du projet.
- Un `SecretProviderClass` qui monte le secret dans
  `/mnt/secrets-store/api-key`, sans créer de `Secret` Kubernetes persistant.

Le secret n'est volontairement ni une variable Terraform ni un secret GitHub :
sinon sa valeur serait stockée dans le state Terraform ou transiterait dans la
CI. Seul son **nom** est versionné dans `key_vault_secret_name`.

## Déploiement

```bash
terraform fmt -recursive
terraform plan -out=tfplan
terraform apply tfplan
```

Après l'apply, reporte les valeurs de `terraform output
github_actions_variables` dans les variables de l'environnement GitHub `dev`.
Les nouvelles variables requises sont `KEY_VAULT_NAME`,
`KEY_VAULT_SECRET_NAME` et `WORKLOAD_IDENTITY_CLIENT_ID`.

Crée ensuite le secret depuis un poste d'administration qui dispose d'une route
privée vers le VNet (bastion, VPN ou runner self-hosted). Le Key Vault n'accepte
volontairement aucun accès public :

```bash
az keyvault secret set \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "demo-app-api-key" \
  --value "<valeur-saisie-hors-historique-shell>"
```

Ne place pas la valeur réelle dans une commande enregistrée par le shell, un
fichier suivi par Git ou `terraform.tfvars`. En exploitation, privilégier une
injection depuis le gestionnaire de secrets d'entreprise ou un terminal qui ne
conserve pas l'historique.

Un push modifiant `k8s/app/` appliquera le ServiceAccount, le
`SecretProviderClass` et le Deployment. Le webhook Workload Identity injecte le
token projeté nécessaire au CSI provider uniquement parce que le template du
pod porte le label `azure.workload.identity/use: "true"`.

## Vérification sans divulguer le secret

Depuis le chemin d'administration actuel du cluster privé :

```bash
az aks command invoke \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw aks_cluster_name)" \
  --command "kubectl rollout status deployment/demo-app -n demo-app --timeout=180s && kubectl exec deployment/demo-app -n demo-app -- test -s /mnt/secrets-store/api-key"
```

La seconde commande valide uniquement que le fichier monté est non vide : elle
ne l'affiche jamais dans les logs de Command Invoke ou de la CI.
