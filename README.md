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

Le cluster est **privé** : l'API server n'a pas d'IP publique et
`authorized_ip_ranges` n'a **aucun effet** sur un cluster privé. Options :

1. **Sans route réseau vers le VNet** : `az aks command invoke`, qui exécute
   la commande dans un pod éphémère du cluster avec ton token Entra (il faut
   donc un rôle data plane, cf. `admin_object_ids`) :
   ```bash
   az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes"
   ```
2. **Réaliste** : bastion/jump box dans le VNet, VPN point-to-site, ou runner
   self-hosted dans le VNet — puis `az aks get-credentials` + `kubectl`.

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

> Le déploiement par `az aks command invoke` décrit ici a été remplacé par
> GitOps en Phase 5 : la CI ne fait plus de `kubectl apply` et n'a plus de
> droits Kubernetes. Section conservée pour l'historique de conception.

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

# 2. Côté GitHub : créer l'environnement "dev" et y reporter les variables
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

> **Note (Phase 5)** : `AKS RBAC Writer` ne couvre pas les ressources
> personnalisées comme `SecretProviderClass` (`customresources/*`). Un rôle
> custom avait été ajouté à la CI pour y remédier ; il a été supprimé en
> Phase 5, où Flux applique les manifestes et où la CI n'a plus aucun droit
> Kubernetes. Leçon à retenir pour tout futur principal Entra qui doit gérer
> des CRD : prévoir un rôle avec les DataActions `customresources/*`.

## Déploiement

```bash
terraform fmt -recursive
terraform plan -out=tfplan
terraform apply tfplan
```

Les valeurs non secrètes consommées par les manifestes (nom du coffre, tenant,
client ID Workload Identity, nom du secret) sont injectées par Flux depuis
Terraform depuis la Phase 5 (`${VAR}` dans `k8s/app/key-vault.yaml`).

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

Flux applique le ServiceAccount, le `SecretProviderClass` et le Deployment
depuis `k8s/app/`. Le webhook Workload Identity injecte le
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

---

# Phase 5 — GitOps avec Flux

## Ce qui change

Avant : la CI poussait l'image **et** faisait `kubectl apply` via
`az aks command invoke` (CI et CD mélangés, droits Kubernetes sur l'identité
CI, aucune correction de dérive). Désormais :

```
app/ modifié ──► CI : build → Trivy → push ACR → commit du digest dans Git
                                                       │
                     cluster privé                     ▼
   Flux (pull, sortie via LB) ◄──── GitHub main : k8s/platform + k8s/app
        │
        ├─ Kustomization "platform" : Namespace, NetworkPolicies de base
        └─ Kustomization "app" (après platform) : ServiceAccount,
           SecretProviderClass, Deployment, Service, NetworkPolicy
```

- `modules/gitops` : extension AKS managée `microsoft.flux`, configuration
  Flux `gitops` (scope cluster, namespace `flux-system`), deux kustomizations
  avec **prune** (un objet retiré de Git est supprimé du cluster) et
  **health checks** (`wait`). Les valeurs non secrètes (Key Vault, tenant,
  client ID Workload Identity) sont injectées par substitution `postBuild`.
- Authentification Git : **deploy key SSH en lecture seule** générée par
  Terraform (`tls_private_key`, RSA PEM, format exigé par l'extension). Clé
  d'hôte GitHub **épinglée** (empreintes officielles), pas de `ssh-keyscan`.
- CI (`deploy.yml`) : plus aucun `kubectl`. Le job `deploy` commite le
  **digest** de l'image (`@sha256:…`, immuable) dans
  `k8s/app/kustomization.yaml`, puis attend que la configuration Flux soit
  `Compliant` sur ce commit en lisant son état via ARM.
- Droits CI réduits à : `AcrPush` + `Reader` ACR, et un rôle custom
  `managedClusters/read` + `fluxConfigurations/read`. **Aucun rôle data
  plane Kubernetes, plus de `command invoke`.**
- `flux-system` ajouté aux namespaces exclus de la baseline Pod Security
  (composant managé, même logique que `calico-system`).

## Mise en place (ordre important)

```bash
# 1. Installer Flux. Sans deploy key enregistrée, Flux ne peut pas encore
#    cloner : rien n'est appliqué, aucun risque sur l'existant.
terraform plan -out=tfplan && terraform apply tfplan

# 2. Ajouter la variable GitHub FLUX_CONFIGURATION_NAME (environnement dev)
#    depuis : terraform output github_actions_variables
#    Les variables KEY_VAULT_*, WORKLOAD_IDENTITY_CLIENT_ID et APP_NAMESPACE
#    ne sont plus utilisées par le workflow.

# 3. Pousser le code sur main AVANT d'enregistrer la deploy key : sinon Flux
#    lirait les anciens manifestes (placeholders) et les appliquerait.

# 4. Enregistrer la deploy key en lecture seule
terraform output -raw flux_deploy_key_public > flux.pub
gh repo deploy-key add flux.pub --repo <owner>/<repo> --title "flux-aks-dev" && rm flux.pub
```

## Exploitation

- **Déployer une nouvelle version** : modifier `app/` et pousser ; la CI
  commite le digest, Flux déploie (intervalle de synchronisation : 60 s).
- **Modifier un manifeste** : commit dans `k8s/` ; aucun build, Flux applique.
- **Rollback** : `git revert` du commit `deploy(demo-app): …` — le digest
  précédent est redéployé.
- **Dérive** : toute modification manuelle d'un objet géré est écrasée à la
  réconciliation suivante.
- **État Flux sans accès au cluster** :
  ```bash
  az k8s-configuration flux show -g <rg> -c <cluster> -t managedClusters -n gitops \
    --query "{commit:sourceSyncedCommitId, state:complianceState, statuses:statuses}"
  ```

## Compromis assumés

- **Clé privée de la deploy key dans le state Terraform** (backend azurerm
  avec authentification Entra uniquement). Alternative écartée pour l'instant :
  clé créée hors Terraform et référencée via `local_auth_reference`.
- **Flux est cluster-admin** (RBAC Kubernetes du ServiceAccount
  kustomize-controller, indépendant d'Azure RBAC). Durcissement possible :
  impersonation d'un ServiceAccount limité au namespace.
- **La CI garde un droit d'écriture sur le dépôt** (`contents: write` limité
  au job `deploy`), nécessaire pour déclarer le digest.