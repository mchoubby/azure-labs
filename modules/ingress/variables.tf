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
variable "subnet_id" {
  type = string
}
variable "aks_oidc_issuer_url" {
  type = string
}
variable "node_resource_group_id" {
  type = string
}
variable "log_analytics_workspace_id" {
  type = string
}
variable "tags" {
  type    = map(string)
  default = {}
}
