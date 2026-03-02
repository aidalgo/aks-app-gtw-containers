resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

data "azurerm_client_config" "current" {}

locals {
  rg_name         = "rg-${var.name_prefix}-${random_string.suffix.result}"
  aks_name        = "aks-${var.name_prefix}-${random_string.suffix.result}"
  vnet_name       = "vnet-${var.name_prefix}-${random_string.suffix.result}"
  aks_subnet_name = "snet-aks-${var.name_prefix}-${random_string.suffix.result}"
  agc_subnet_name = "snet-agc-${var.name_prefix}-${random_string.suffix.result}"
  alb_name        = "alb-${var.name_prefix}-${random_string.suffix.result}"
  frontend_name         = "frontend-${random_string.suffix.result}"
  ingress_frontend_name = "frontend-ingress-${random_string.suffix.result}"
  association_name       = "assoc-${random_string.suffix.result}"
  waf_policy_name = "waf-${var.name_prefix}-${random_string.suffix.result}"
  config_mgr_role = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/fbc52c3f-28ad-4303-a892-8a056630b8f1"
  network_contrib = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
}

# ── Resource Group ────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
}

# ── Networking ────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "aks" {
  name                 = local.aks_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.aks_subnet_address_prefix]
}

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

# ── AKS Cluster ───────────────────────────────────────────────────────
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
  node_count            = 1
  os_sku                = "AzureLinux"
  mode                  = "User"
  vnet_subnet_id        = azurerm_subnet.aks.id
}

# ── Enable ALB controller add-on + Gateway API ───────────────────────
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

# ── ALB controller managed identity ──────────────────────────────────
data "azurerm_user_assigned_identity" "alb_controller" {
  name                = "applicationloadbalancer-${local.aks_name}"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group

  depends_on = [azapi_update_resource.enable_agc_addons]
}

# ── RBAC: ALB controller needs permissions on the RG, subnet, and WAF ─
resource "azurerm_role_assignment" "alb_config_manager_on_rg" {
  scope              = azurerm_resource_group.rg.id
  role_definition_id = local.config_mgr_role
  principal_id       = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_role_assignment" "alb_network_contributor_on_agc_subnet" {
  scope              = azurerm_subnet.agc.id
  role_definition_id = local.network_contrib
  principal_id       = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_role_assignment" "alb_network_contributor_on_waf" {
  scope              = azurerm_web_application_firewall_policy.waf.id
  role_definition_id = local.network_contrib
  principal_id       = data.azurerm_user_assigned_identity.alb_controller.principal_id
}

# ── WAF Policy ────────────────────────────────────────────────────────
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
    priority  = 2
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
    priority  = 3
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

  # IP allowlist: when allowed_source_ranges is set, block any source IP
  # NOT in the list. AGC frontends are always public, so this is the
  # recommended way to restrict access to known networks.
  # See: https://learn.microsoft.com/azure/application-gateway/for-containers/application-gateway-for-containers-components
  dynamic "custom_rules" {
    for_each = length(var.allowed_source_ranges) > 0 ? [1] : []
    content {
      name      = "AllowOnlyKnownIPs"
      priority  = 1
      rule_type = "MatchRule"
      action    = "Block"

      match_conditions {
        match_variables {
          variable_name = "RemoteAddr"
        }
        operator           = "IPMatch"
        negation_condition = true
        match_values       = var.allowed_source_ranges
      }
    }
  }
}

# ── BYO: Create AGC traffic controller, frontend, and association ─────
# Using azapi_resource instead of local-exec so that Terraform manages the
# full lifecycle (create, read, update, delete) — no more orphaned resources.
resource "azapi_resource" "traffic_controller" {
  type      = "Microsoft.ServiceNetworking/trafficControllers@2023-11-01"
  name      = local.alb_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location

  body = {
    properties = {}
  }

  depends_on = [
    azurerm_role_assignment.alb_config_manager_on_rg,
    azurerm_role_assignment.alb_network_contributor_on_agc_subnet,
  ]
}

resource "azapi_resource" "frontend" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/frontends@2023-11-01"
  name      = local.frontend_name
  parent_id = azapi_resource.traffic_controller.id
  location  = azurerm_resource_group.rg.location

  body = {
    properties = {}
  }
}

# A second frontend for the Ingress demo. AGC requires each frontend to be
# assigned to at most one Gateway or Ingress resource.
resource "azapi_resource" "ingress_frontend" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/frontends@2023-11-01"
  name      = local.ingress_frontend_name
  parent_id = azapi_resource.traffic_controller.id
  location  = azurerm_resource_group.rg.location

  body = {
    properties = {}
  }
}

resource "azapi_resource" "association" {
  type      = "Microsoft.ServiceNetworking/trafficControllers/associations@2023-11-01"
  name      = local.association_name
  parent_id = azapi_resource.traffic_controller.id
  location  = azurerm_resource_group.rg.location

  body = {
    properties = {
      associationType = "subnets"
      subnet = {
        id = azurerm_subnet.agc.id
      }
    }
  }
}
