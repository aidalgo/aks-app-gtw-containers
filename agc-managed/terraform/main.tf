resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  rg_name         = "rg-${var.name_prefix}-${random_string.suffix.result}"
  aks_name        = "aks-${var.name_prefix}-${random_string.suffix.result}"
  vnet_name       = "vnet-${var.name_prefix}-${random_string.suffix.result}"
  subnet_name     = "snet-aks-${var.name_prefix}-${random_string.suffix.result}"
  agc_subnet_name = "snet-agc-${var.name_prefix}-${random_string.suffix.result}"
  waf_policy_name = "waf-${var.name_prefix}-${random_string.suffix.result}"
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

# Dedicated subnet for the AGC frontend.
# Must be delegated to Microsoft.ServiceNetworking/trafficControllers.
resource "azurerm_subnet" "agc" {
  name                 = local.agc_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.agc_subnet_address_prefix]

  delegation {
    name = "agc-delegation"
    service_delegation {
      name = "Microsoft.ServiceNetworking/trafficControllers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = local.aks_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  dns_prefix = "dns${random_string.suffix.result}"

  identity {
    type = "SystemAssigned"
  }

  # Keep it private (API server reachable only via private networking)
  private_cluster_enabled = true
  private_dns_zone_id     = "System"

  default_node_pool {
    name           = "system"
    node_count     = var.system_node_count
    vm_size        = var.node_vm_size
    os_sku         = "AzureLinux"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  # Azure CNI Overlay: nodes use real subnet IPs, pods get IPs from a
  # virtual overlay network — satisfies the AGC add-on requirement.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
  }

  # Requirement for AGC add-on: Workload Identity enabled (+ OIDC issuer)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.node_vm_size
  node_count            = 1
  os_sku                = "AzureLinux"
  mode                  = "User"
  vnet_subnet_id        = azurerm_subnet.aks.id
}

# Enable:
# - AKS managed Gateway API add-on
# - Application Gateway for Containers "Application Load Balancer" add-on
#
# properties.ingressProfile.applicationLoadBalancer.enabled = true
# properties.ingressProfile.gatewayAPI.installation = "Standard"
# using api-version=2025-09-02-preview. :contentReference[oaicite:5]{index=5}
resource "azapi_update_resource" "enable_agc_addons" {
  type        = "Microsoft.ContainerService/managedClusters@2025-09-02-preview"
  resource_id = azurerm_kubernetes_cluster.aks.id

  body = {
    location = azurerm_kubernetes_cluster.aks.location
    properties = {
      ingressProfile = {
        applicationLoadBalancer = {
          enabled = true
        }
        gatewayAPI = {
          installation = "Standard"
        }
      }
    }
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_node_pool.apps,
  ]
}

# The add-on creates a dedicated managed identity in the node resource group.
# Its name is always: applicationloadbalancer-<cluster-name>
data "azurerm_user_assigned_identity" "alb_controller" {
  name                = "applicationloadbalancer-${local.aks_name}"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group

  depends_on = [azapi_update_resource.enable_agc_addons]
}

# Look up the node resource group so we can scope the Contributor role to it.
data "azurerm_resource_group" "node_rg" {
  name       = azurerm_kubernetes_cluster.aks.node_resource_group
  depends_on = [azurerm_kubernetes_cluster.aks]
}

# 1. Network Contributor on the delegated AGC subnet
#    Allows the ALB controller to attach the frontend to the subnet.
resource "azurerm_role_assignment" "alb_subnet_network_contributor" {
  scope                = azurerm_subnet.agc.id
  role_definition_name = "Network Contributor"
  principal_id         = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

# 2. Contributor on the node resource group
#    Allows the ALB controller to create/manage AGC (trafficController) resources
#    inside the MC_... resource group.
resource "azurerm_role_assignment" "alb_node_rg_contributor" {
  scope                = data.azurerm_resource_group.node_rg.id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

# 3. Network Contributor on the WAF policy resource
#    Grants the ALB controller the join/action permission it needs to attach
#    the WAF policy to the AGC security policy via the WebApplicationFirewallPolicy CR.
resource "azurerm_role_assignment" "alb_waf_policy_network_contributor" {
  scope                = azurerm_web_application_firewall_policy.waf.id
  role_definition_name = "Network Contributor"
  principal_id         = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

# Azure WAF policy for the Gateway API demo.
# AGC only supports Default Rule Set (DRS) — not the classic OWASP CRS.
# A custom rule blocks any request whose User-Agent contains "BadBot",
# which makes it easy to demo in a curl command.
resource "azurerm_web_application_firewall_policy" "waf" {
  name                = local.waf_policy_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
  }

  custom_rules {
    name      = "BlockBadBots"
    priority  = 1
    rule_type = "MatchRule"
    action    = "Block"

    match_conditions {
      match_variables {
        variable_name = "RequestHeaders"
        selector      = "User-Agent"
      }
      operator           = "Contains"
      negation_condition = false
      match_values       = ["BadBot"]
    }
  }

  custom_rules {
    name      = "BlockUriToken"
    priority  = 2
    rule_type = "MatchRule"
    action    = "Block"

    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator           = "Contains"
      negation_condition = false
      match_values       = ["blockme"]
    }
  }
}