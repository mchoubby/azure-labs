#!/usr/bin/env bash
# Bootstrap du backend Terraform : Storage Account dédié au state.
#
# Volontairement en CLI et pas en Terraform : on ne peut pas gérer avec
# Terraform la ressource qui héberge son propre state (problème de l'œuf
# et de la poule). Ce script ne tourne qu'une seule fois, à la création
# du projet.
set -euo pipefail

RG_NAME="rg-tfstate"
LOCATION="francecentral"
# Le nom d'un Storage Account doit être globalement unique sur Azure (tous
# tenants confondus) et limité à 24 caractères alphanumériques minuscules.
SA_NAME="sttfstate$(openssl rand -hex 4)"
CONTAINER_NAME="tfstate"

echo "==> Resource group ${RG_NAME}"
az group create --name "${RG_NAME}" --location "${LOCATION}" -o none

echo "==> Storage account ${SA_NAME}"
az storage account create \
  --name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  -o none

# Le versioning des blobs permet de revenir sur une version antérieure du
# state en cas de corruption ou d'apply malheureux (ex: state écrasé par
# un run concurrent mal locké).
echo "==> Blob versioning + soft delete"
az storage account blob-service-properties update \
  --account-name "${SA_NAME}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  -o none

echo "==> Container ${CONTAINER_NAME}"
# Auth via Azure AD (login-based), pas de clé d'accès stockée nulle part :
# c'est ton identité connectée (az login) qui doit avoir le rôle
# "Storage Blob Data Contributor" sur ce compte, assigné juste après.
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${SA_NAME}" \
  --auth-mode login \
  -o none

echo "==> Role assignment (Storage Blob Data Contributor) pour l'utilisateur courant"
SA_ID=$(az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" --query id -o tsv)
USER_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --assignee "${USER_ID}" \
  --role "Storage Blob Data Contributor" \
  --scope "${SA_ID}" \
  -o none

az storage account show --name "sttfstate3059d5e4" --resource-group "rg-tfstate" --query id -o tsv
az role assignment create --assignee "f6bd34c4-bf3d-4a0e-bf48-abbc14a03046" --role "Storage Blob Data Contributor" --scope "/subscriptions/4183c77e-63f1-44b0-9324-dde1ea9143c9/resourceGroups/rg-tfstate/providers/Microsoft.Storage/storageAccounts/sttfstate3059d5e4" -o none
cat <<EOF

Bootstrap terminé.

Storage account : ${SA_NAME}
Resource group   : ${RG_NAME}
Container        : ${CONTAINER_NAME}

Renseigne ces valeurs dans backend.hcl, puis lance :
  terraform init -backend-config=backend.hcl -migrate-state

(La propagation du role assignment peut prendre 1-2 minutes avant le premier init.)
EOF
