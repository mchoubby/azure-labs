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
4. **DevSecOps** (Gatekeeper/OPA, Network Policies, Key Vault CSI) — à faire
5. **GitOps** (Flux/ArgoCD) — à faire
6. **Observabilité et résilience** (Prometheus/Grafana, HPA, chaos test) — à faire

## Architecture actuelle (Phases 1-3)

```
*.tf (racine)       # root module — assemble les 4 modules (pas encore de découpage envs/)
modules/network/    # VNet + 3 subnets (aks-nodes, private-endpoints, appgw) + NSG
modules/aks/        # cluster privé, CNI Overlay, Workload Identity, node pools system+user
modules/acr/        # ACR Premium + Private Endpoint + zone privatelink.azurecr.io, AcrPull kubelet
modules/ci/         # UAMI fédérée OIDC (subject = environment GitHub), AcrPush+Reader ACR,
                    # rôle custom "command invoke" sur le cluster, RBAC Writer sur le namespace
.github/workflows/deploy.yml   # build → scan Trivy (sans accès Azure) → [env dev] push ACR → command invoke
app/                           # appli de démo (nginx-unprivileged, /healthz sur 8080)
k8s/namespace.yaml             # appliqué une fois par un admin, pas par la CI
k8s/deployment.yaml            # manifeste d'exemple, à remplacer par la vraie appli
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
- Le pipeline fait le `kubectl apply` lui-même (CI et CD mélangés) — sera
  corrigé en Phase 5 avec un vrai GitOps (Flux/ArgoCD).

## État du déploiement réel
Le cluster Phase 1-3 a été réellement déployé et migré (pas juste du code
jamais appliqué) : `terraform apply` fait à chaque phase, state migré vers
modules via `terraform state mv` (`scripts/migrate-state-to-modules.sh`).
Phase 3 appliquée, `demo-app` déployé par la CI (2/2 pods, image tirée via le Private Endpoint).

## Prochaine étape demandée par l'utilisateur
Phase 4 — DevSecOps : Azure Policy/Gatekeeper (OPA), Network Policies (Calico,
déjà activé au niveau cluster mais pas encore de policies définies), Key Vault
CSI driver pour les secrets.