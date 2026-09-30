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
  description = "Utilisé pour scoper le role assignment Network Contributor de l'identité du cluster"
  type        = string
}

variable "aks_nodes_subnet_id" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "system_node_count" {
  type = number
}

variable "system_node_vm_size" {
  type = string
}

variable "user_node_min_count" {
  type = number
}

variable "user_node_max_count" {
  type = number
}

variable "user_node_vm_size" {
  type = string
}

variable "admin_object_ids" {
  description = "Object IDs Azure AD (utilisateurs/groupes) à qui accorder le rôle 'AKS RBAC Cluster Admin' sur ce cluster"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
