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
  value = azapi_resource.traffic_controller.name
}

output "alb_id" {
  value = azapi_resource.traffic_controller.id
}

output "frontend_name" {
  value = azapi_resource.frontend.name
}

output "ingress_frontend_name" {
  value = azapi_resource.ingress_frontend.name
}

output "association_id" {
  value = azapi_resource.association.id
}

output "agc_subnet_id" {
  value = azurerm_subnet.agc.id
}

output "waf_policy_id" {
  value = azurerm_web_application_firewall_policy.waf.id
}
