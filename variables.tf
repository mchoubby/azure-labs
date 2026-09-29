variable "project_name" {
  description = "Préfixe utilisé pour nommer toutes les ressources"
  type        = string
  default     = "aksdemo"
}

variable "location" {
  description = "Région Azure de déploiement"
  type        = string
  default     = "francecentral"
}

variable "environment" {
  description = "Environnement (dev, staging, prod) — utilisé dans le naming et les tags"
  type        = string
  default     = "dev"
}

variable "vnet_address_space" {
  description = "Espace d'adressage du VNet"
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "aks_nodes_subnet_cidr" {
  description = "Subnet dédié aux nodes AKS"
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_endpoints_subnet_cidr" {
  description = "Subnet dédié aux Private Endpoints (Key Vault, ACR, etc.)"
  type        = string
  default     = "10.20.2.0/24"
}

variable "appgw_subnet_cidr" {
  description = "Subnet réservé pour l'App Gateway / ingress (utilisé en phase ultérieure)"
  type        = string
  default     = "10.20.3.0/24"
}

variable "kubernetes_version" {
  description = "Version de Kubernetes pour le cluster AKS"
  type        = string
  default     = "1.36"
}

variable "system_node_count" {
  description = "Nombre de nodes du pool system"
  type        = number
  default     = 2
}

variable "system_node_vm_size" {
  description = "SKU des VM du pool system"
  type        = string
  default     = "Standard_D2ds_v6"
}

variable "user_node_min_count" {
  description = "Min nodes du pool user (autoscaling)"
  type        = number
  default     = 1
}

variable "user_node_max_count" {
  description = "Max nodes du pool user (autoscaling)"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "SKU des VM du pool user"
  type        = string
  default     = "Standard_D4ds_v6"
}

variable "tags" {
  description = "Tags communs appliqués à toutes les ressources"
  type        = map(string)
  default = {
    project    = "aks-fintech-demo"
    managed_by = "terraform"
  }
}
