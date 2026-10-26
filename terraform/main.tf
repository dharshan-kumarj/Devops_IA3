# The six resources the assignment asks for, in dependency order:
#   Resource Group -> Virtual Network -> Subnet -> Public IP -> Network Interface
#   -> Virtual Machine
# plus a Network Security Group, which is not on the list but is required in
# practice: an Azure subnet denies all inbound traffic from the internet until
# an NSG rule allows it, so without this the web app would be unreachable.

# ---- 1. Resource Group ------------------------------------------------------
# A container for everything below. Deleting it deletes the whole deployment,
# which is how you stop spending credit when the demo is over.
resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

# ---- 2. Virtual Network -----------------------------------------------------
# A private address range that belongs only to this deployment.
resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# ---- 3. Subnet --------------------------------------------------------------
# A slice of the VNet that the VM's network card actually sits in.
resource "azurerm_subnet" "app" {
  name                 = "${var.prefix}-subnet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
}

# ---- Network Security Group (firewall) --------------------------------------
# Static means the IP survives a VM restart, so the URL in the report keeps
# working and the Jenkins credential does not have to be edited after a reboot.
resource "azurerm_network_security_group" "app" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # Ansible (run by Jenkins) deploys over SSH, so port 22 must be open to
  # wherever Jenkins runs. Narrow allowed_ssh_cidr to your own IP if you can.
  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  # The web app itself. This one has to be open to the world, otherwise the
  # faculty cannot open the URL.
  security_rule {
    name                       = "allow-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# ---- 4. Public IP -----------------------------------------------------------
resource "azurerm_public_ip" "app" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ---- 5. Network Interface ---------------------------------------------------
# The virtual network card: it joins the subnet and carries the public IP.
resource "azurerm_network_interface" "app" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

# ---- 6. Virtual Machine -----------------------------------------------------
# Ubuntu 22.04 LTS. cloud-init installs Docker on first boot, so by the time
# Jenkins first deploys there is already a Docker daemon waiting.
resource "azurerm_linux_virtual_machine" "app" {
  name                  = "${var.prefix}-vm"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.app.id]
  tags                  = var.tags

  # Azure refuses password authentication when this is true, which removes the
  # single most common way a student VM gets taken over by a bot.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "${var.prefix}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    admin_username = var.admin_username
  }))
}
