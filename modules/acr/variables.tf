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
  description = "VNet lié à la zone DNS privée privatelink.azurecr.io"
  type        = string
}

variable "private_endpoints_subnet_id" {
  type = string
}

variable "kubelet_identity_object_id" {
  description = "Identité des nodes AKS, qui reçoit AcrPull"
  type        = string
}

variable "public_network_access_enabled" {
  description = "Endpoint public de l'ACR. Nécessaire tant que la CI tourne sur des runners GitHub hébergés (hors VNet)"
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
