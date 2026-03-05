output "acr_name" {
  description = "Container registry name"
  value       = azurerm_container_registry.main.name
}

output "acr_login_server" {
  description = "Container registry login server FQDN"
  value       = azurerm_container_registry.main.login_server
}

output "acr_id" {
  description = "Container registry resource ID"
  value       = azurerm_container_registry.main.id
}
