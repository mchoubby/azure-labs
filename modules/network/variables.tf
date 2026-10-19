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

variable "vnet_address_space" {
  type = list(string)
}

variable "aks_nodes_subnet_cidr" {
  type = string
}

variable "private_endpoints_subnet_cidr" {
  type = string
}

variable "appgw_subnet_cidr" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
variable "ingress_enabled" {
  type    = bool
  default = false
}
