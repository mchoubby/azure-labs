# Phase 1 — Fondations réseau et cluster AKS

## Mise en pause et reprise du lab — 19 octobre 2026

Suppression complète demandée pour arrêter les coûts, **backend Terraform
inclus**. Les phases ci-dessous décrivent l'architecture et l'historique du
lab, pas une infrastructure à supposer encore déployée. La Phase 7 reste
préparée mais non appliquée ; `ingress_enabled` reste désactivé par défaut.

**Suppression terminée et vérifiée le 19 octobre 2026** : aucun resource
group ni aucune ressource active retournés par Azure dans la souscription
du lab, backend et Network Watcher compris. Le state Terraform final ne
contient plus de ressources. AKS a été supprimé sans redémarrage ; Flux a
nécessité une suppression forcée côté ARM sur le cluster arrêté, puis une
nouvelle destruction Terraform a réconcilié le state. La solution Container
Insights orpheline a également été supprimée.

Sauvegarde locale hors dépôt, avec accès Windows limité à l'utilisateur et
à SYSTEM : `C:\Users\moham\azure-labs-backups\2026-10-19-teardown`.
Elle contient les states avant destruction (`before-destroy.tfstate`) et
après destruction (`after-destroy.tfstate`, vide), les paramètres du backend,
les variables Terraform et les modifications locales de la Phase 7.
Les anciens states et plans locaux ont été déplacés dans
`old-local-artifacts` pour éviter leur réutilisation accidentelle.
**Le state avant destruction contient une clé privée Flux : ne pas le
committer ni le partager.** Les images ACR et les données applicatives ne
sont pas sauvegardées par le state.

### Pour reprendre ultérieurement

1. Reconnecter Azure CLI à la bonne souscription. Recréer le stockage du
   backend et le conteneur `tfstate` avec l'authentification Entra ; attribuer
   `Storage Blob Data Contributor` **avant** de créer le conteneur, puis
   attendre la propagation RBAC. Le script `scripts/bootstrap-backend.sh`
   fournit les paramètres, mais son ordre conteneur/rôle doit être adapté
   si l'utilisateur n'a pas déjà les droits data-plane.
2. Actualiser `backend.hcl` avec le nouveau nom de stockage, puis exécuter
   `terraform init -reconfigure -backend-config=backend.hcl`. Repartir d'un
   state vide : **ne pas restaurer le state avant destruction** et ne pas
   réutiliser les anciens plans.
3. Revoir les coûts, les quotas régionaux et les versions avant un nouveau
   `terraform plan`, puis un `terraform apply` explicite. Un redémarrage ne
   suffit pas : le cluster doit être recréé.
4. Actualiser les variables GitHub de l'environnement `dev` depuis
   `terraform output github_actions_variables` (les identités changent).
   Remplacer l'ancienne deploy key Flux par la nouvelle, en conservant
   l'ordre GitOps décrit en Phase 5.
5. Reconstruire et publier l'image dans le nouvel ACR, actualiser le digest
   GitOps via la CI et recréer le secret applicatif dans Key Vault via un
   accès privé. L'ancien digest Git ne suffit pas à restaurer l'image.
6. Revalider Flux, les pods, CSI et l'observabilité avant d'activer la Phase 7.

Le coffre `kvaksdemodeva3b521` est en suppression logique avec protection
contre la purge jusqu'au **17 janvier 2027**. Avant cette date, prévoir sa
récupération avec vérification du plan Terraform et de ses accès, ou un nom
différent ; ne pas tenter de contourner la protection contre la purge.

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

---

# Phase 6 — Observabilité et résilience

## Architecture

`modules/monitoring` provisionne **Azure Monitor workspace** (Managed
Prometheus), le Data Collection Endpoint, la Data Collection Rule et son
association au cluster, ainsi que **Azure Managed Grafana Standard X1**.
L'activation `monitor_metrics` dans `modules/aks` installe les agents
`ama-metrics`. La collecte suit le
[template Terraform officiel Azure](https://github.com/Azure/prometheus-collector/tree/main/AddonTerraformTemplate).
Cluster, workspace et DCE restent dans `francecentral` : aucune association
DCE supplémentaire pour un décalage de régions.

Le workspace Prometheus est distinct du **Log Analytics existant**, qui
conserve les logs Container Insights. Pas de duplication de Log Analytics.
Grafana utilise une identité managée avec `Monitoring Data Reader` sur le
workspace uniquement. Les identités `admin_object_ids` reçoivent `Grafana
Admin`. Endpoint Grafana et requêtes Prometheus sont publics mais
authentifiés Entra ; pas d'accès anonyme ni de clé API Grafana. L'API AKS
reste privée et la CI ne reçoit aucun droit supplémentaire.

**HPA et Prometheus ont deux circuits indépendants** : le HPA consulte
Metrics Server (`metrics.k8s.io`), pas Managed Prometheus. La cible CPU
60 % est relative aux **requests** (100m) : environ 60m par replica en
moyenne, pas 60 % de la limite 250m.

## Résilience déclarative

- Pool user : **min 1 / max 5**, mais **un seul node en pratique**. Le quota
  `standardDDSv6Family` de francecentral est à 10 vCPU (system 2×2 + user
  1×4 = 8) et son augmentation est refusée en libre-service
  (`QuotaNotAvailableForResource`, même à 16). Le max à 5 est conservé pour
  le jour où le quota sera relevé.
- `demo-app` ciblé sur le pool user, répartition **préférentielle** par
  hostname : `maxSkew=1`, `ScheduleAnyway`. Avec un seul node, tous les
  replicas y sont : aucune résilience à la perte d'un node. La contrainte
  reprendra son effet dès qu'un deuxième node existe ; repasser alors en
  `DoNotSchedule` + `minDomains=2` pour une garantie stricte.
- HPA `autoscaling/v2` : **2 à 5 replicas**, CPU **60 %**, croissance
  limitée à deux pods par minute ; réduction limitée à un pod par minute,
  avec fenêtre de stabilisation de 300 s.
- PDB `policy/v1` : **minAvailable=1**.
- Rolling update : `maxUnavailable=0`, `maxSurge=1`.
- `spec.replicas` absent de la cible Git : le HPA gère ce champ, Flux ne
  doit pas ramener périodiquement le Deployment à deux replicas.

Le PDB protège les **évictions volontaires** (drain), pas une suppression
directe de pod ni une panne brutale. Le cluster autoscaler répond aux pods
non planifiables, pas directement à la CPU. Ici, s'il tente un scale-out
(pods Pending faute de CPU sur le node), la création échoue sur le quota :
événements `FailedScaleUp`/`NotTriggerScaleUp` attendus, pods Pending
jusqu'au scale-down du HPA. Ce n'est pas une panne du cluster.

**Limite connue — mise à jour du pool user** : la surge (33 % d'un node =
un D4ds_v6 de plus) dépasse le quota, et `max_unavailable` sans surge
serait bloqué par le PDB (les pods évincés n'ont aucun autre node). Une
mise à jour de version du pool user nécessitera un quota temporaire ou une
coupure acceptée.

## Déploiement — ne pas pousser toute la bascule d'un seul coup

1. Vérifier AKS `Running`, les quotas vCPU (régional **et** par famille de
   VM, surge comprise) et le coût de Grafana Standard X1. Enregistrer les
   providers manquants, avec accord explicite :
   ```powershell
   az provider register --namespace Microsoft.Monitor --wait
   az provider register --namespace Microsoft.Dashboard --wait
   ```
   Vérifier aussi `Microsoft.Insights` et `Microsoft.AlertsManagement`.
   Terraform exige au moins une identité dans `admin_object_ids`.
2. `terraform plan` puis `terraform apply` après revue : pas de remplacement
   du cluster. Vérifier le node user Ready et les agents `ama-metrics`.
3. Bascule en **deux commits GitOps** :
   - premier commit : HPA, PDB et répartition, en conservant temporairement
     `spec.replicas: 2` dans le Deployment ; attendre HPA sain, deux replicas
     Ready et Flux Compliant ;
   - second commit : retirer `spec.replicas` (état cible fourni ici), puis
     vérifier le HPA et `metadata.managedFields`.

   **Constaté au déploiement réel** : les deux commits ne suffisent pas à
   éviter la baisse transitoire. Le HPA n'écrit `replicas` (via `/scale`)
   que s'il **change** la valeur ; à 2 = minReplicas il n'écrit rien, donc
   `kustomize-controller` reste seul propriétaire du champ. Quand il le
   retire de son apply SSA, l'API server le remet à sa valeur par défaut
   (**1**) : un pod supprimé, puis recréé ~5 s plus tard par le HPA
   (`Current number of replicas below Spec.MinReplicas`). Le PDB ne
   protège pas ce cas (pas une éviction). Pour une bascule sans baisse :
   dans le commit 1, mettre `minReplicas` au-dessus du `replicas` Git
   (ex. 3) afin que le HPA écrive le champ et en devienne copropriétaire,
   puis retirer `replicas` et revenir à `minReplicas: 2`.
   Ensuite, `kustomize-controller` ne possède plus `spec.replicas` : Flux ne
   le remet plus à deux. Ne pas utiliser un `kubectl scale` comme état durable.
4. Vérifier le secret CSI **sur les nouveaux pods**, sans afficher sa valeur,
   puis importer le dashboard et réaliser les tests ci-dessous.
   Aucun test perturbateur n'est déclenché par le workflow CI.

## Accès Grafana et métriques

```powershell
terraform output -raw grafana_endpoint
terraform output -raw prometheus_query_endpoint
.\scripts\test-resilience.ps1 -Scenario Diagnose
```

Ouvrir l'endpoint Grafana et se connecter avec une identité autorisée dans
Entra. Importer `dashboards/aks-phase6.json` dans Grafana, sélectionner
la source **Azure Managed Prometheus** associée, puis le cluster.
Ce dashboard versionné utilise les métriques brutes (CPU, mémoire,
replicas, HPA et redémarrages), sans dépendre des recording rules
des dashboards communautaires. Les données et chaque panneau doivent
être vérifiés après apply ; un dashboard sans données n'est pas un succès.

Dans Explore (source Prometheus), vérifier des séries **récentes** :
```promql
up
kube_deployment_status_replicas_available{namespace="demo-app",deployment="demo-app"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="demo-app",horizontalpodautoscaler="demo-app"}
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo-app",container="demo-app"}[5m]))
```

Ajouter le filtre `cluster` affiché dans Grafana si le workspace collecte
plusieurs clusters. Pas d'exporter nginx ni de métriques HTTP applicatives :
la sonde du test mesure les réponses HTTP séparément.

## Tests contrôlés depuis PowerShell

`scripts/test-resilience.ps1` utilise `az aks command invoke`, avec ton
identité d'administration, pas celle de la CI. `Diagnose` ne modifie pas
les workloads applicatifs (command invoke crée son pod technique).
Les autres scénarios demandent confirmation ; `-WhatIf` n'exécute rien.

Préparer **avec accord explicite** une image BusyBox de test dans ACR
(par exemple version 1.37.0), vérifier sa provenance et son scan, récupérer
son digest, puis fournir la référence immuable :
```powershell
$image = "acraksdemodeva3b521.azurecr.io/phase6/busybox@sha256:<digest>"
.\scripts\test-resilience.ps1 -Scenario Load -TestImage $image -WhatIf
.\scripts\test-resilience.ps1 -Scenario Load -TestImage $image -DurationSeconds 300 -Concurrency 8
.\scripts\test-resilience.ps1 -Scenario DeletePod -TestImage $image -PodName "<pod-demo-app>"
.\scripts\test-resilience.ps1 -Scenario Drain -TestImage $image -NodeName "<node-user>" -DurationSeconds 300
```

Les Jobs temporaires sont non-root, limités en ressources, sans token API
ni secret CSI, dans `demo-app` pour réutiliser DNS et les règles réseau
intra-namespace. Ils sont hors des chemins réconciliés par Flux. Les noms
sont uniques par exécution ; nettoyage en `finally`, TTL et deadline
complètent la protection si le processus est interrompu.
Les commandes shell des Jobs sont normalisées en LF avant sérialisation
JSON : les fins de ligne Windows CRLF provoquent des erreurs de syntaxe
dans BusyBox. Si la sonde ne devient pas Ready, le script affiche ses
descriptions et logs avant de la supprimer.

- **Load** : charge HTTP bornée (1–32 workers, 30–600 s). Le script exige un
  scale-out mesuré (`desiredReplicas > 2` et plus de deux replicas Ready,
  sans dépasser cinq), sinon il échoue. nginx statique peut ne pas saturer
  à faible charge : ajuster la concurrence dans les limites, sans déclarer
  un succès fictif. Vérifier ensuite le retour à deux et l'absence de conflit
  avec Flux après la stabilisation.
- **DeletePod** : un seul pod explicitement nommé, appartenant à un
  ReplicaSet de demo-app ; observer remplacement et secret CSI.
- **Drain** : un seul node user explicitement nommé ; **refusé tant qu'il
  n'y a pas au moins deux nodes user planifiables** (avec un seul node, les
  pods évincés n'auraient nulle part où aller et le PDB bloquerait le drain).
  Non exécutable avec le quota actuel. Inspecter les pods
  et PDB de **tous** ses namespaces avant de confirmer ; le drain peut
  déplacer d'autres workloads. Il utilise l'éviction et respecte les PDB,
  sans `--force` ni contournement. `--delete-emptydir-data` supprime les
  données éphémères des pods évincés : ne pas lancer si d'autres workloads
  en dépendent. Un drain bloqué échoue, il n'est pas forcé. Le script remet
  le node planifiable, puis vérifie la récupération du Deployment.

La sonde affiche codes HTTP, nombre de tentatives et échecs ; toute erreur
HTTP/réseau rend le test non réussi. Vérifier aussi pendant la perturbation
qu'au moins un replica reste Ready. Ce test d'éviction volontaire ne
simule pas une panne brutale de VM.

## Critères de fin et retour arrière

Phase terminée uniquement après : Grafana accessible via Entra, métriques
récentes, Flux Compliant, HPA sain et scale-out/down mesurés, PDB présent,
sonde HTTP sans erreur, secret CSI non vide, aucun Job de test résiduel.
Répartition multi-nodes et drain : reportés tant que le quota impose un
seul node user. Conserver les résultats des tests.

Rollback applicatif : `git revert` des commits Phase 6 ; réintroduire
`replicas: 2` si le HPA est retiré.
Retirer l'observabilité nécessite un plan Terraform revu ; cela détruit
Grafana et le workspace, donc potentiellement les dashboards et les métriques.

**Coûts** : Grafana, le workspace et les autres ressources Azure ne sont pas
arrêtés par `az aks stop`. Ne pas confondre arrêt AKS et destruction de
l'observabilité.

---

# Phase 7 — Entree publique HTTPS, Gateway API et WAF

**Etat : code prepare, pas applique.** `ingress_enabled = false` par
defaut : pousser les fichiers ne cree pas de point d'entree public.
La Phase 6 est cloturee a la demande de Med : Grafana et cinq panneaux
avec donnees recentes, test Load reussi selon son retour (scale-out > 2
Ready, FAILED=0). DeletePod non verifie, drain reporte et controles
post-test non executes car AKS etait stoppe.

## Architecture et ownership

```text
Internet -> frontend AGC :443 -> WAF Prevention -> pods demo-app :8080
             :80 -> redirection HTTPS
Terraform : AGC + frontend + association subnet + SecurityPolicy + WAF
            UAMI/federation/RBAC + diagnostics vers le Log Analytics existant
Flux      : charts ALB/cert-manager + Certificate + Gateway + HTTPRoutes
            association WAF + politique TLS + NetworkPolicy applicative
```

- **Application Gateway for Containers**, pas Application Gateway WAF_v2
  classique ni AGIC. Le dataplane Azure atteint directement les IP pods
  via l'integration CNI Overlay ; le Service reste ClusterIP et l'API AKS
  reste privee.
- **BYO** : Terraform possede le cycle de vie Azure. Le Gateway reference
  l'ID AGC et le frontend existants ; aucune CR `ApplicationLoadBalancer`
  ne demande au controleur de creer une infrastructure concurrente.
- Subnet existant `snet-appgw`, **exactement /24**, meme VNet que les
  nodes, delegue a `Microsoft.ServiceNetworking/trafficControllers`.
- ALB Controller **1.12.2** et cert-manager **v1.21.2**, charts OCI officiels
  epingles par digest. Le nouvel add-on ALB AKS est encore en preview :
  installation Helm par Flux, sans add-on preview ni provider Kubernetes
  Terraform qui devrait joindre l'API privee.
- Les controleurs et hooks vont sur les nodes system avec la toleration
  `CriticalAddonsOnly`. Surveiller leur capacite disponible (deux D2ds_v6).
- UAMI dediee federee au SA `azure-alb-system/alb-controller-sa` ;
  Configuration Manager scope a l'AGC, Network Contributor au seul subnet,
  Reader au node resource group. Aucun nouveau droit pour la CI.
- Flux installe les charts avant les CR avec deux Kustomizations dependantes,
  `ingress-controllers` puis `ingress-config` (wait et timeout 10 min).
- NetworkPolicy additive : subnet AGC uniquement vers `demo-app:8080`.
  Les regles intra-namespace et deny-by-default existantes restent intactes.
  Verifier le comportement effectif de Calico/CNI Overlay au deploiement ;
  ne pas ouvrir tout le VNet pour contourner une erreur 502.

## TLS de demonstration et WAF

Pas de domaine a acheter : utiliser le **FQDN fourni par le frontend AGC**.
cert-manager genere le certificat auto-signe avec ce FQDN comme SAN,
valide 90 jours et renouvelle 15 jours avant expiration, avec rotation de cle.
Le Secret `demo-ingress-tls` est cree dans Kubernetes, pas dans Git ni dans
le state Terraform. Les permissions Kubernetes permettant de lire des
Secrets restent sensibles.

Le navigateur affiche un avertissement de confiance : **chiffrement ne
signifie pas certificat public de confiance**. Le script de validation
recupere uniquement le certificat public via l'acces admin authentifie et
utilise `curl --cacert`, jamais `-k`. Cette confiance locale doit etre
renouvelee lors de la rotation du certificat. Pour une vraie application :
domaine + certificat public, hors du perimetre de cette demonstration.

- TLS policy `2023-06-S` (TLS 1.2 minimum).
- Terminaison TLS sur AGC, HTTP vers nginx : pas de TLS end-to-end dans ce lab.
- WAF **Prevention**, Microsoft DRS **2.1** (pas OWASP CRS, non supporte
  sur AGC). SecurityPolicy Azure autorise l'association ; la CR
  `WebApplicationFirewallPolicy` l'applique au Gateway.
- Regle de validation non offensive : `X-Demo-WAF-Test: block` doit
  retourner **403**, la meme requete sans cet en-tete doit retourner **200**.
  Cela prouve le raccordement WAF, pas l'efficacite de toutes les regles DRS.

## Ordre de deploiement (manuel)

1. Relire les changements, commiter et pousser **tous** les fichiers Phase 7
   avant activation Terraform. Ne pas pousser de state, plan, tfvars local
   ou Secret TLS. Conserver `ingress_enabled = false` pendant ce push.
2. Revoir les couts : AGC, frontend, capacite, WAF, ingestion/retention des logs.
   Ils ne sont pas supprimes par `az aks stop`. Aucun prix fixe garanti ici :
   utiliser le calculateur Azure pour francecentral.
3. Avec accord explicite, enregistrer les providers manquants (constates
   NotRegistered lors de la preparation) :
   ```powershell
   az provider register --namespace Microsoft.ServiceNetworking --wait
   az provider register --namespace Microsoft.NetworkFunction --wait
   ```
4. Redemarrer AKS s'il est stoppe et attendre Running/Succeeded :
   ```powershell
   az aks start -g rg-aksdemo-dev -n aks-aksdemo-dev
   ```
5. Ajouter `ingress_enabled = true` dans le tfvars local, puis :
   ```powershell
   terraform init
   terraform plan -out=tfplan-phase7
   terraform apply tfplan-phase7
   ```
   Plan attendu de la preparation : **11 creations, 2 modifications,
   0 destruction** (delegation subnet et configuration Flux). Aucun
   remplacement AKS ni changement de taille/nombre des nodes.
   Les roles peuvent necessiter quelques minutes de propagation ; inspecter
   les logs ALB si l'authentification echoue.
6. Lire les conditions Flux, HelmRelease, Certificate, Gateway et HTTPRoute
   via `az aks command invoke`. Ne pas se limiter au statut ARM Compliant :
   les deux Kustomizations enfants doivent etre Ready, et les listeners
   Accepted/ResolvedRefs/Programmed sur la generation courante.
7. Tester depuis Windows :
   ```powershell
   terraform output -raw ingress_url
   .\scripts\test-ingress.ps1
   ```
   Le script ne modifie pas les workloads. Il lit les ressources et le
   certificat **public**, puis envoie trois requetes : HTTP -> HTTPS **301**,
   HTTPS `/healthz` **200** avec validation TLS, test WAF **403**.
   `command invoke` cree son pod technique habituel.

## Logs, verification et rollback

Diagnostic setting `allLogs` + `AllMetrics` sur AGC, vers le workspace
Log Analytics AKS existant (pas le workspace Prometheus). Verifier dans
Logs les categories access/firewall apres les requetes (delai d'ingestion).
Exemple pour le mode AzureDiagnostics configure par defaut :

```kusto
AzureDiagnostics
| where TimeGenerated > ago(30m)
| where ResourceProvider =~ "MICROSOFT.SERVICENETWORKING"
| summarize Nombre=count() by Category
```

Phase terminee seulement apres : HTTPS valide avec confiance explicite,
redirection correcte, blocage WAF observe et log correspondant, Flux et
controleurs Ready, backend sain, Service toujours ClusterIP sans autre
endpoint public de l'application. Aucune validation reelle Phase 7
effectuee tant qu'elle n'est pas appliquee. Alertes HTTP et certificat
public de production : evolutions ulterieures, pas deja configurees.

Rollback en deux temps : retirer d'abord les ressources de routage/TLS/WAF
Kubernetes et attendre le prune Flux, puis retirer les controleurs si
inutilises, **avant** de mettre `ingress_enabled = false` et d'appliquer
la destruction Azure. Ne pas detruire le dataplane sous un Gateway actif.
Les CRD Helm et le Secret TLS peuvent etre conserves apres suppression :
verifier leurs proprietaires et nettoyer explicitement les seuls objets
Phase 7 devenus inutiles. Ne jamais supprimer le namespace `demo-app`.

References officielles :
- [AGC et CNI Overlay](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking)
- [Installation ALB Helm](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm)
- [WAF et limitations](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/web-application-firewall)
- [TLS policy](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/tls-policy)