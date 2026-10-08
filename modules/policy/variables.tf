variable "aks_cluster_id" {
  type = string
}

variable "acr_login_server" {
  description = "Seul registry autorisé dans les namespaces applicatifs"
  type        = string
}

variable "app_namespaces" {
  description = "Namespaces soumis au profil restricted et à la restriction d'images"
  type        = list(string)
}

variable "system_namespaces" {
  description = "Namespaces exclus de la baseline (composants AKS gérés, privilégiés par nature)"
  type        = list(string)
  default = [
    "kube-system",
    "gatekeeper-system",
    "azure-arc",
    "azure-extensions-usage-system",
    "calico-system",
    "tigera-operator",
    "aks-command",
    "flux-system",
  ]
}

variable "effect" {
  description = "Audit pour mesurer la conformité sans rien bloquer, Deny pour refuser à l'admission"
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.effect)
    error_message = "effect doit valoir Audit, Deny ou Disabled."
  }
}
