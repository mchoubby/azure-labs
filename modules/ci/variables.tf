variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  description = "Scope de création et d'assignation du rôle custom command invoke"
  type        = string
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

variable "github_repository" {
  description = "Dépôt GitHub autorisé à se fédérer, au format owner/repo"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository doit être au format owner/repo."
  }
}

variable "github_repository_ids" {
  description = "IDs numériques GitHub du owner et du repo, si le repo émet des subjects OIDC au format immutable (repo:owner@<id>/repo@<id>:...)"
  type = object({
    owner_id      = number
    repository_id = number
  })
  default = null
}

variable "github_environment" {
  description = "Environnement GitHub Actions dont les jobs peuvent obtenir un token Azure"
  type        = string
}

variable "acr_id" {
  type = string
}

variable "aks_cluster_id" {
  type = string
}

variable "app_namespace" {
  description = "Namespace Kubernetes dans lequel la CI a les droits d'écriture"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
