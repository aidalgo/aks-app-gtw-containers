variable "location" {
  type    = string
  default = "eastus2"
}

variable "name_prefix" {
  type    = string
  default = "nginx-demo"
}

variable "system_node_count" {
  type    = number
  default = 1
}

variable "apps_node_count" {
  type    = number
  default = 1
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.0.0.0/8"]
  description = "Address space for the virtual network."
}

variable "subnet_address_prefix" {
  type        = string
  default     = "10.240.0.0/16"
  description = "Address prefix for the AKS node subnet."
}
