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
  frontend_name   = "frontend-${random_string.suffix.result}"
  association_name = "assoc-${random_string.suffix.result}"
  waf_policy_name = "waf-${var.name_prefix}-${random_string.suffix.result}"
  config_mgr_role = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/fbc52c3f-28ad-4303-a892-8a056630b8f1"
  network_contrib = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
  alb_id          = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_resource_group.rg.name}/providers/Microsoft.ServiceNetworking/trafficControllers/${local.alb_name}"
  frontend_id     = "${local.alb_id}/frontends/${local.frontend_name}"
  association_id  = "${local.alb_id}/associations/${local.association_name}"
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

# ── BYO: Create AGC traffic controller, frontend, and association ─────
resource "terraform_data" "create_byo_agc" {
  input = {
    resource_group = azurerm_resource_group.rg.name
    alb_name       = local.alb_name
    frontend_name  = local.frontend_name
    association    = local.association_name
    subnet_id      = azurerm_subnet.agc.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if ! az extension show --name alb >/dev/null 2>&1; then
        az extension add --name alb >/dev/null
      fi

      if ! az network alb show -g "${self.input.resource_group}" -n "${self.input.alb_name}" >/dev/null 2>&1; then
        az network alb create -g "${self.input.resource_group}" -n "${self.input.alb_name}" >/dev/null
      fi

      if ! az network alb frontend show -g "${self.input.resource_group}" --alb-name "${self.input.alb_name}" -n "${self.input.frontend_name}" >/dev/null 2>&1; then
        az network alb frontend create -g "${self.input.resource_group}" --alb-name "${self.input.alb_name}" -n "${self.input.frontend_name}" >/dev/null
      fi

      if ! az network alb association show -g "${self.input.resource_group}" --alb-name "${self.input.alb_name}" -n "${self.input.association}" >/dev/null 2>&1; then
        az network alb association create -g "${self.input.resource_group}" --alb-name "${self.input.alb_name}" -n "${self.input.association}" --subnet "${self.input.subnet_id}" >/dev/null
      fi
    EOT
  }

  depends_on = [
    azurerm_role_assignment.alb_config_manager_on_rg,
    azurerm_role_assignment.alb_network_contributor_on_agc_subnet,
    azurerm_role_assignment.alb_network_contributor_on_waf,
  ]
}
