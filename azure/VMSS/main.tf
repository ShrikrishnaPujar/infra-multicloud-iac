# Author: Shrikrishna Pujar
# Creation Date: 2026-06-18
# Synopsis: Deploys an Azure Windows VM Scale Set with autoscaling, load balancing, RDP access, and outbound internet connectivity.
# Description: This Terraform configuration provisions a resource group, virtual network, subnet, standard public load balancer, backend pool, NAT pool for RDP, outbound rule for internet access, NSG with RDP allowance, a Windows Server 2025 VMSS, and CPU-based autoscale rules.

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy      = false
      recover_soft_deleted_key_vaults   = false
    }
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "vmss-rg"
  location = "Central India"

  tags = {
    Environment = "Development"
    Project     = "VMSS-Autoscale"
    Owner       = "Shrikrishna Pujar"
    CreatedDate = "2026-06-18"
  }
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vmss-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_subnet" "subnet" {
  name                 = "vmss-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# PUBLIC IP
resource "azurerm_public_ip" "pip" {
  name                = "vmss-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = azurerm_resource_group.rg.tags
}

# MANAGED IDENTITY
resource "azurerm_user_assigned_identity" "vmss_identity" {
  name                = "vmss-managed-identity"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = azurerm_resource_group.rg.tags
}

# KEY VAULT
resource "azurerm_key_vault" "kv" {
  name                       = "kv-vmss-${random_string.kv_suffix.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Recover",
      "Purge"
    ]
  }

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = "b0f78cec-99b3-4ab9-b07c-42f794e7bd0f"

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Recover",
      "Purge"
    ]
  }

  tags = azurerm_resource_group.rg.tags
}

# KEY VAULT SECRET FOR ADMIN PASSWORD
resource "azurerm_key_vault_secret" "admin_password" {
  name         = "vmss-admin-password"
  value        = "Password@123#"
  key_vault_id = azurerm_key_vault.kv.id
}

# RANDOM STRING FOR KEY VAULT UNIQUE NAME
resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# DATA SOURCE FOR CURRENT AZURE CONTEXT
data "azurerm_client_config" "current" {}

# LOAD BALANCER
resource "azurerm_lb" "lb" {
  name                = "vmss-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontend"
    public_ip_address_id = azurerm_public_ip.pip.id
  }

  tags = azurerm_resource_group.rg.tags
}

# HEALTH PROBE
resource "azurerm_lb_probe" "health_probe" {
  loadbalancer_id     = azurerm_lb.lb.id
  name                = "tcp-health-probe"
  protocol            = "Tcp"
  port                = 3389
  interval_in_seconds = 15
  number_of_probes    = 2
}

# BACKEND POOL
resource "azurerm_lb_backend_address_pool" "bepool" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "backendpool"
}

# NAT RULE FOR RDP
resource "azurerm_lb_nat_pool" "rdp" {
  resource_group_name            = azurerm_resource_group.rg.name
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "rdp-nat-pool"
  protocol                       = "Tcp"
  frontend_port_start            = 50000
  frontend_port_end              = 50100
  backend_port                   = 3389

  frontend_ip_configuration_name = "PublicFrontend"
}

# OUTBOUND RULE FOR INTERNET ACCESS
resource "azurerm_lb_outbound_rule" "internet" {
  name                    = "vmss-outbound-rule"
  loadbalancer_id         = azurerm_lb.lb.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.bepool.id

  allocated_outbound_ports = 1024
  idle_timeout_in_minutes  = 4
  tcp_reset_enabled        = true

  frontend_ip_configuration {
    name = "PublicFrontend"
  }
}

# NETWORK SECURITY GROUP
resource "azurerm_network_security_group" "nsg" {
  name                = "vmss-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# NETWORK SECURITY RULE FOR RDP
resource "azurerm_network_security_rule" "rdp_rule" {
  name                        = "AllowRDP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

# NSG ASSOCIATION WITH SUBNET
resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# VMSS
resource "azurerm_windows_virtual_machine_scale_set" "vmss" {
  name                = "win-vmss"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  sku       = "Standard_B2s"   # LOW COST
  instances = 1                # Start small

  scale_in {
    rule = "NewestVM"
  }

  upgrade_mode = "Automatic"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.vmss_identity.id]
  }

  admin_username = "ShrikrishnaPujar"
  admin_password = azurerm_key_vault_secret.admin_password.value

  computer_name_prefix = "winvm"

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-Datacenter"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = azurerm_subnet.subnet.id

      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.bepool.id
      ]

      load_balancer_inbound_nat_rules_ids = [
        azurerm_lb_nat_pool.rdp.id
      ]
    }
  }

  tags = azurerm_resource_group.rg.tags
}

# AUTOSCALE
resource "azurerm_monitor_autoscale_setting" "autoscale" {
  name                = "vmss-autoscale"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  target_resource_id  = azurerm_windows_virtual_machine_scale_set.vmss.id

  profile {
    name = "defaultProfile"

    capacity {
      minimum = "1"
      maximum = "3"  
      default = "1"
    }

    # Scale OUT
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_windows_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT1M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }

    # Scale IN
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_windows_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT1M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 35
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT1M"
      }
    }
  }
}