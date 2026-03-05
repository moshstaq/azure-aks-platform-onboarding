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
#
# Basic SKU used for lab cost discipline (~$5/month).
# In production use Premium SKU with Private Endpoint
# to restrict image pulls to within the VNet only.
# Private Endpoint pattern already demonstrated in
# the storage module of the landing zone.
# ─────────────────────────────────────────────────────
resource "azurerm_container_registry" "main" {
  name                          = "acraksplatform"
  resource_group_name           = data.terraform_remote_state.networking.outputs.resource_group_name
  location                      = data.terraform_remote_state.networking.outputs.location
  sku                           = "Basic"
  public_network_access_enabled = true
  admin_enabled                 = false

  tags = {
    environment = "dev"
    managed_by  = "terraform"
    workload    = "platform-onboarding"
  }
}
