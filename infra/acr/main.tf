# ─────────────────────────────────────────────────────
# Remote state — landing zone networking
# ─────────────────────────────────────────────────────
data "terraform_remote_state" "networking" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate7tcl"
    container_name       = "tfstate"
    key                  = "landing-zone-app-dev-networking.tfstate"
  }
}

# ─────────────────────────────────────────────────────
# Azure Container Registry
# Premium SKU required for Private Endpoints
# admin_enabled false — authentication via AcrPull RBAC
# ─────────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                          = "acraksplatform"
  resource_group_name           = data.terraform_remote_state.networking.outputs.resource_group_name
  location                      = data.terraform_remote_state.networking.outputs.location
  sku                           = "Premium"
  public_network_access_enabled = false
  admin_enabled                 = false

  tags = {
    environment = "dev"
    managed_by  = "terraform"
    workload    = "platform-onboarding"
  }
}

# ─────────────────────────────────────────────────────
# Private Endpoint — ACR
# NIC in snet-app so AKS nodes pull images inside VNet
# ─────────────────────────────────────────────────────
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-platform"
  location            = data.terraform_remote_state.networking.outputs.location
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group_name
  subnet_id           = data.terraform_remote_state.networking.outputs.snet_app_id

  private_service_connection {
    name                           = "psc-acr-platform"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  tags = {
    environment = "dev"
    managed_by  = "terraform"
  }
}

# ─────────────────────────────────────────────────────
# Private DNS Zone — ACR
# ─────────────────────────────────────────────────────
resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group_name

  tags = {
    environment = "dev"
    managed_by  = "terraform"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-vnet-appdev-acr"
  resource_group_name   = data.terraform_remote_state.networking.outputs.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = data.terraform_remote_state.networking.outputs.vnet_app_dev_id
  registration_enabled  = false

  tags = {
    environment = "dev"
    managed_by  = "terraform"
  }
}

resource "azurerm_private_dns_a_record" "acr" {
  name                = "acraksplatform"
  zone_name           = azurerm_private_dns_zone.acr.name
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.acr.private_service_connection[0].private_ip_address]

  tags = {
    environment = "dev"
    managed_by  = "terraform"
  }
}
