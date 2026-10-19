# AKS Fintech Demo — Contexte projet

## Qui je suis
Med, DevOps/DevSecOps engineer (~8 ans XP) À l'aise sur Jenkins/Azure DevOps/GitLab CI,
Azure, OpenShift/Kubernetes, intégration d'outillage sécurité en pipeline.

Objectif du projet : apprendre AKS en profondeur via un scénario "production-like",
pas un tutoriel jouet. Toutes les explications techniques : en français, précises,
structurées, sans survulgarisation.

## Stack retenue
- IaC : Terraform (pas Bicep)
- CI/CD : GitHub Actions (pas Azure DevOps, pas GitLab CI)
- Cloud : Azure, région francecentral

## Scénario
Déploiement et sécurisation d'une architecture microservices sur AKS pour une
appli fintech-like. Plan en 6 phases :

1. **Fondations réseau + cluster** — ✅ fait
2. **Backend state distant + modularisation Terraform** — ✅ fait
3. **CI/CD GitHub Actions avec OIDC** — ✅ fait (appliqué, pipeline vert de bout en bout)
4. **DevSecOps** (Gatekeeper/OPA, Network Policies, Key Vault CSI) — ✅ fait (appliqué, pods 2/2, secret CSI monté)
5. **GitOps** (Flux via extension AKS managée) — ✅ fait (Flux Compliant, déploiement par digest, CI sans droit Kubernetes)
6. **Observabilité et résilience** — ✅ clôturée à la demande de Med :
   Grafana/métriques vérifiés, Load réussi selon son retour (scale-out > 2,
   FAILED=0). DeletePod non vérifié, drain reporté, contrôles post-test
   bloqués par AKS stoppé.
7. **Entrée HTTPS et WAF** — code préparé, non appliqué : Application Gateway
   for Containers + Gateway API, certificat auto-signé sans domaine,
   Terraform BYO + charts ALB/cert-manager via Flux. Activation explicite
   `ingress_enabled = true`, désactivée par défaut.

## Architecture actuelle (Phases 1-6 + Phase 7 optionnelle)

```
*.tf (racine)       # root module — assemble les modules (pas encore de découpage envs/)
modules/network/    # VNet + 3 subnets (aks-nodes, private-endpoints, appgw) + NSG
modules/aks/        # cluster privé, CNI Overlay, Workload Identity, node pools system+user,
                    # add-ons Azure Policy et Key Vault Secrets Provider (CSI)
modules/acr/        # ACR Premium + Private Endpoint + zone privatelink.azurecr.io, AcrPull kubelet
modules/ci/         # UAMI fédérée OIDC (subject = environment GitHub), AcrPush+Reader ACR,
                    # rôle custom lecture cluster + fluxConfigurations/read. AUCUN droit Kubernetes.
modules/policy/     # Azure Policy (Gatekeeper) : PSS baseline cluster, restricted + images ACR sur l'app
modules/key-vault/  # Key Vault RBAC privé (PE), UAMI applicative fédérée au SA demo-app
modules/gitops/     # extension microsoft.flux + flux configuration "gitops" + deploy key SSH (tls)
modules/monitoring/ # Azure Monitor workspace, DCE/DCR, Managed Grafana et RBAC Entra (Phase 6)
modules/ingress/    # AGC BYO, WAF, identité ALB et diagnostics (Phase 7, désactivée par défaut)
.github/workflows/deploy.yml   # build → Trivy (sans accès Azure) → [env dev] push ACR →
                               # commit du digest dans k8s/app/kustomization.yaml → attente Flux Compliant (ARM)
app/                           # appli de démo (nginx-unprivileged, /healthz sur 8080)
k8s/platform/                  # Kustomization Flux "platform" : namespace + NetworkPolicies baseline
k8s/app/                       # Kustomization Flux "app" : SA, SecretProviderClass, Deployment, Service, netpol, HPA/PDB
k8s/ingress/                   # Flux enfants : charts ALB/cert-manager puis Gateway API/TLS/WAF/netpol
```

## Décisions techniques clés (à ne pas re-proposer de changer sans discussion)
- **Azure CNI Overlay** (pas kubenet, pas CNI classique) — évite l'épuisement d'IP
- **Cluster AKS privé** — API server sans IP publique
- **Azure AD Workload Identity** activé dès la Phase 1 (OIDC issuer) — pas encore
  utilisé mais évite un recreate du cluster en Phase 4
- **Azure RBAC natif** (`azure_rbac_enabled = true`) — être Owner Azure NE DONNE
  PAS les droits kubectl, il faut un role assignment data-plane explicite
  (`Azure Kubernetes Service RBAC Cluster Admin` pour les humains, géré via
  `admin_object_ids` dans `terraform.tfvars`)
- **Backend Terraform `azurerm`** avec `use_azuread_auth = true` — pas de clé
  de storage account committée nulle part
- **ACR sans compte admin**, tout en identités managées (kubelet via AcrPull,
  CI via AcrPush)
- **GitHub Actions en OIDC fédéré** — aucun secret Azure stocké côté GitHub

## Pièges déjà rencontrés (ne pas les refaire)
1. **`api_server_access_profile.authorized_ip_ranges` ne fonctionne PAS sur un
   cluster privé** — je l'avais mis par erreur en Phase 1, retiré depuis. Accès
   au cluster privé sans VPN/bastion : `az aks command invoke`.
2. **Owner Azure ≠ droits kubectl** quand `azure_rbac_enabled = true`. Toujours
   prévoir le role assignment data-plane explicite.
3. **Supply chain attack sur `aquasecurity/trivy-action` (mars 2026)** — tous
   les tags antérieurs à `v0.35.0` sont compromis (credentials volés, tags
   réécrits). Le workflow épingle `v0.36.0`. Ne jamais redescendre en dessous
   de `v0.35.0`.
4. **Runner GitHub hébergé ne peut pas joindre un cluster privé** (pas de route
   réseau vers le VNet) — d'où l'usage de `az aks command invoke` plutôt qu'un
   `kubectl apply` direct dans le pipeline.

5. **Subject OIDC GitHub au format immutable** : le repo émet
   `repo:mchoubby@15172350/azure-labs@1398410375:environment:dev` (IDs
   numériques), pas `repo:owner/repo:...`. Géré via `github_repository_ids`
   dans `terraform.tfvars`. Symptôme si mauvais format : `AADSTS700213`.
6. **Tag de branche nginx arrêtée = CVE non corrigées** : `1.29-alpine` n'était
   plus reconstruit (38 HIGH/CRITICAL). Rester sur la branche stable courante
   (`1.30-alpine3.24`) + `apk upgrade` au build.

7. **Exclusions par défaut des initiatives Pod Security Azure incomplètes** :
   elles n'excluent ni `calico-system`/`tigera-operator` (pods privilégiés,
   hostNetwork) ni `aks-command` (pods de `az aks command invoke`). En Deny
   cluster-wide sans ces exclusions : Calico ne redémarre plus, la CI et
   l'accès admin au cluster privé cassent. Liste complète dans
   `modules/policy/variables.tf` (`system_namespaces`).
8. **Cluster stoppé = aucun update possible** sur la ressource AKS (et donc
   rien de ce qui en dépend dans le graphe Terraform).
9. **`AKS RBAC Writer` ne couvre pas les CRD** (`SecretProviderClass`…) :
   il faut les DataActions `managedClusters/customresources/*` (rôle custom).
   Symptôme : `Forbidden ... cannot get resource "secretproviderclasses"`.
10. **Ordre de bascule GitOps** : ne jamais donner à Flux l'accès au repo
    (deploy key) avant que `k8s/*/kustomization.yaml` soit sur main — sans
    kustomization.yaml, Flux applique tous les YAML du dossier tels quels.
11. **Quota vCPU = régional ET par famille de VM** (surge et max autoscaler
    compris). `cores` est passé à 24 en libre-service, mais
    `standardDDSv6Family` (francecentral) reste à 10 : `az quota update`
    renvoie `QuotaNotAvailableForResource`. D'où un seul node user.
    Vérifier avec `az vm list-usage -l francecentral` avant tout scale-out.
12. **Retirer `spec.replicas` d'un manifest appliqué en SSA (Flux) le remet
    à 1** si le HPA n'a jamais écrit le champ (il n'écrit que s'il change la
    valeur). Constaté en Phase 6 : un pod supprimé puis recréé ~5 s après.
    Forcer d'abord une écriture du HPA (minReplicas > replicas Git).
13. **`az aks command invoke --command` depuis Windows** : `az` est un
    `.cmd`, les `|`, `$()` et `{"\n"}` sont interprétés par cmd.exe.
    Passer les scripts par `--file` (`--command "sh script.sh"`).

## Compromis assumés, à challenger si possible
- ~~Contributor sur le cluster pour la CI~~ → remplacé par un rôle custom
  (`managedClusters/read`, `runcommand/action`, `commandResults/read`) +
  `AKS RBAC Writer` scopé au namespace applicatif (command invoke exécute
  kubectl avec le token Entra de l'appelant, donc un rôle data plane est requis).
- **ACR avec endpoint public activé** (auth Entra uniquement, pas d'admin, pas
  de pull anonyme) : le runner GitHub hébergé ne peut pas joindre le Private
  Endpoint. Les nodes tirent via le PE. À fermer
  (`acr_public_network_access_enabled = false`) dès qu'un runner self-hosted
  dans le VNet existe.
- ~~Le pipeline fait le `kubectl apply` lui-même~~ → Flux (Phase 5). La CI
  garde `contents: write` (job deploy uniquement) pour commiter le digest.
- **Deploy key Flux générée par Terraform** : clé privée dans le state
  (backend azurerm, auth Entra). Alternative : `local_auth_reference`.
- **Flux cluster-admin** (RBAC Kubernetes du SA kustomize-controller) —
  durcissement possible par impersonation d'un ServiceAccount de namespace.
- **Les pods demo-app sur le même node** : PDB présent depuis la Phase 6,
  mais pas de résilience à la perte du node (quota DDSv6).
- **Phase 6 retenue** : **un seul node user** en pratique (min 1 / max 5,
  quota DDSv6 bloqué : tout scale-out échoue), topology
  spread par hostname en `ScheduleAnyway` (préférence, effective seulement
  avec plusieurs nodes), HPA CPU 2-5 cible 60 %, PDB minAvailable=1. Aucune
  résilience à la perte du node user ; drain et mise à jour du pool user
  impossibles sans quota supplémentaire. Retrait de replicas dans Git après
  mise en place du HPA.
- **Observabilité managée** : endpoints publics Entra pour Prometheus et
  Grafana, aucune clé API ; AKS reste privé. Grafana Standard reste facturé
  pendant un arrêt AKS. Tests manuels bornés, pas de Chaos Studio/Chaos Mesh.

## État du déploiement réel
Le cluster Phase 1-3 a été réellement déployé et migré (pas juste du code
jamais appliqué) : `terraform apply` fait à chaque phase, state migré vers
modules via `terraform state mv` (`scripts/migrate-state-to-modules.sh`).
Phases 3 à 5 appliquées (Flux réconcilie k8s/platform et k8s/app depuis main) : `demo-app` 2/2 pods, image tirée via le Private
Endpoint, secret Key Vault monté via CSI + Workload Identity. Azure Policy
pilotée par `policy_effect` (`Audit` par défaut).

## Prochaine étape
Phase 7 — relire et pousser le code avant activation, revoir les coûts,
enregistrer Microsoft.ServiceNetworking et Microsoft.NetworkFunction,
redémarrer AKS avec accord puis plan/apply manuels. Attendu : 11 créations,
2 modifications, 0 destruction. Voir README.
Vérifier Flux enfants, charts, certificat, Gateway/routes, HTTPS 200,
redirection 301, WAF 403 et logs. Aucun apply ni redémarrage effectué par
l'assistant pendant la préparation. Phase 7 non terminée.