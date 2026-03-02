variable "location" {
  type    = string
  default = "eastus2"
}

variable "system_node_count" {
  type    = number
  default = 1
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "name_prefix" {
  type    = string
  default = "agc-demo"
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

variable "agc_subnet_address_prefix" {
  type        = string
  default     = "10.241.0.0/24"
  description = "Address prefix for the AGC (Application Gateway for Containers) frontend subnet."
}

variable "allowed_source_ranges" {
  type        = list(string)
  default     = []
  description = "List of CIDR ranges allowed to reach the AGC frontend. When non-empty, a WAF custom rule blocks all other source IPs. Leave empty to allow all traffic (open to the internet)."
}