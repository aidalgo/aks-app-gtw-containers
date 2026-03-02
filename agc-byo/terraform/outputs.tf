output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "aks_node_resource_group" {
  value = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "alb_name" {
  value = local.alb_name
}

output "alb_id" {
  value      = local.alb_id
  depends_on = [terraform_data.create_byo_agc]
}

output "frontend_name" {
  value      = local.frontend_name
  depends_on = [terraform_data.create_byo_agc]
}

output "association_id" {
  value      = local.association_id
  depends_on = [terraform_data.create_byo_agc]
}

output "agc_subnet_id" {
  value = azurerm_subnet.agc.id
}

output "waf_policy_id" {
  value = azurerm_web_application_firewall_policy.waf.id
}
