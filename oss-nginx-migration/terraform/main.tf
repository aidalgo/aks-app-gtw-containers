resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  rg_name     = "rg-${var.name_prefix}-${random_string.suffix.result}"
  aks_name    = "aks-${var.name_prefix}-${random_string.suffix.result}"
  vnet_name   = "vnet-${var.name_prefix}-${random_string.suffix.result}"
  subnet_name = "snet-aks-${var.name_prefix}-${random_string.suffix.result}"
}

resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "aks" {
  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_address_prefix]
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = local.aks_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  dns_prefix = "dns${random_string.suffix.result}"

  identity {
    type = "SystemAssigned"
  }

  private_cluster_enabled = true
  private_dns_zone_id     = "System"

  default_node_pool {
    name           = "system"
    node_count     = var.system_node_count
    vm_size        = var.node_vm_size
    os_sku         = "AzureLinux"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.node_vm_size
  node_count            = var.apps_node_count
  os_sku                = "AzureLinux"
  mode                  = "User"
  vnet_subnet_id        = azurerm_subnet.aks.id
}
