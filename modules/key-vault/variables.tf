variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vnet_id" {
  description = "VNet lié à la zone DNS privée du Key Vault"
  type        = string
}

variable "private_endpoints_subnet_id" {
  type = string
}

variable "aks_oidc_issuer_url" {
  description = "Issuer OIDC du cluster AKS pour la fédération Workload Identity"
  type        = string
}

variable "tenant_id" {
  type = string
}

variable "app_namespace" {
  type = string
}

variable "service_account_name" {
  type    = string
  default = "demo-app"
}

variable "secret_name" {
  description = "Nom du secret à créer manuellement dans le Key Vault puis à monter dans le pod"
  type        = string
  default     = "demo-app-api-key"
}

variable "tags" {
  type    = map(string)
  default = {}
}
