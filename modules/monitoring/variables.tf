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

variable "aks_cluster_id" {
  type = string
}

variable "aks_cluster_name" {
  type = string
}

variable "admin_object_ids" {
  type = set(string)

  validation {
    condition     = length(var.admin_object_ids) > 0
    error_message = "Au moins une identité Entra est requise pour accéder à Grafana."
  }
}

variable "tags" {
  type = map(string)
}
