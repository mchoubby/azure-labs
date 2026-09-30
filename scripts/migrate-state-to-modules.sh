#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT_DIR}"

echo "==> Initialisation du backend et des modules"
terraform init -backend-config=backend.hcl

echo "Ressources actuelles dans le state :"
terraform state list
echo
read -p "Confirme que la liste ci-dessus correspond à ta Phase 1 (y/n) : " CONFIRM
[[ "$CONFIRM" == "y" ]] || { echo "Annulé."; exit 1; }

mv_pairs=(
  "data.azurerm_client_config.current|module.aks.data.azurerm_client_config.current"
  "azurerm_virtual_network.main|module.network.azurerm_virtual_network.main"
  "azurerm_subnet.aks_nodes|module.network.azurerm_subnet.aks_nodes"
  "azurerm_subnet.private_endpoints|module.network.azurerm_subnet.private_endpoints"
  "azurerm_subnet.appgw|module.network.azurerm_subnet.appgw"
  "azurerm_network_security_group.aks_nodes|module.network.azurerm_network_security_group.aks_nodes"
  "azurerm_subnet_network_security_group_association.aks_nodes|module.network.azurerm_subnet_network_security_group_association.aks_nodes"
  "azurerm_user_assigned_identity.aks_control_plane|module.aks.azurerm_user_assigned_identity.aks_control_plane"
  "azurerm_role_assignment.aks_network_contributor|module.aks.azurerm_role_assignment.aks_network_contributor"
  "azurerm_log_analytics_workspace.aks|module.aks.azurerm_log_analytics_workspace.aks"
  "azurerm_kubernetes_cluster.main|module.aks.azurerm_kubernetes_cluster.main"
  "azurerm_kubernetes_cluster_node_pool.user|module.aks.azurerm_kubernetes_cluster_node_pool.user"
)

RBAC_ADDRESS="azurerm_role_assignment.aks_rbac_cluster_admin"
if terraform state list | grep -qx "${RBAC_ADDRESS}"; then
  ADMIN_OBJECT_ID=$(terraform state show -no-color "${RBAC_ADDRESS}" | awk -F'"' '/principal_id/ { print $2; exit }')
  [[ -n "${ADMIN_OBJECT_ID}" ]] || { echo "Impossible de lire le principal_id du rôle AKS." >&2; exit 1; }
  mv_pairs+=("${RBAC_ADDRESS}|module.aks.azurerm_role_assignment.aks_admins[\"${ADMIN_OBJECT_ID}\"]")
fi

for pair in "${mv_pairs[@]}"; do
  from="${pair%%|*}"
  to="${pair##*|}"
  echo "==> ${from}  ->  ${to}"
  terraform state mv "${from}" "${to}"
done

echo
echo "azurerm_resource_group.main reste inchangé (toujours à la racine du root module)."
echo
echo "Prochaine étape, depuis la racine du projet :"
echo "  terraform plan    # doit annoncer 0 to add, 0 to change, 0 to destroy"
