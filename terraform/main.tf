##############################################################################
# HashiCorp Terraform and Vault Workshop
#
# This Terraform configuration will create the following:
#
# Azure Resource group with a virtual network and subnet
# A Linux server running HashiCorp Vault and a simple application
# A hosted Azure MySQL database server

/* This is the provider block. We recommend pinning the provider version to
a known working version. If you leave this out you'll get the latest
version. */

provider "azurerm" {
  version = "=1.30.1"
}

/* This configures terraform to use the enterprise backend */

terraform {
  backend "atlas" {
    name         = "$${var.workshop-prefix}/$${var.prefix}"
    address      = "https://ptfe.andy-work.hashidemos.io"
    access_token = "rKoFFMjqma0wEw.atlasv1.szKiF7yeSDipWfpnNUZTxZce3oUcqIzsX16GquqrpapbrPsrPzxFvSW2GdzYSeg5UUE"
  }
}

/* This is a data import block. This is used to collect data from another source
When using terraform enterprise, this allows you to pull in data from another workspace,
in our case, the networking information for this workshop */

data "terraform_remote_state" "networking" {
  backend = "remote"

  config = {
    organization = var.workshop-prefix
    workspaces = {
      name = "networking"
    }
  }
}

/* A network interface. This is required by the azurerm_virtual_machine
resource. Terraform will let you know if you're missing a dependency. */
resource "azurerm_network_interface" "vault-nic" {
  name                      = "${var.prefix}-${var.workshop-prefix}-vault-nic"
  location                  = var.location
  resource_group_name       = data.terraform_remote_state.networking.outputs.resource_group
  network_security_group_id = data.terraform_remote_state.networking.outputs.vault_sg

  ip_configuration {
    name                          = "${var.prefix}-${var.workshop-prefix}ipconfig"
    subnet_id                     = data.terraform_remote_state.networking.outputs.subnet
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vault-pip.id
  }
}

/* Every Azure Virtual Machine comes with a private IP address. You can also
optionally add a public IP address for Internet-facing applications and
demo environments like this one. */

resource "azurerm_public_ip" "vault-pip" {
  name                = "${var.prefix}-${var.workshop-prefix}-ip"
  location            = var.location
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group
  allocation_method   = "Dynamic"
  domain_name_label   = "${var.prefix}-${var.workshop-prefix}"
}

/* And finally we build our Vault server. This is a standard Ubuntu instance.
We use the shell provisioner to run a Bash script that configures Vault for
the demo environment. Terraform supports several different types of
provisioners including Bash, Powershell and Chef. */

resource "azurerm_virtual_machine" "vault" {
  name                = "${var.prefix}-${var.workshop-prefix}-vault"
  location            = var.location
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group
  vm_size             = var.vm_size

  network_interface_ids         = [azurerm_network_interface.vault-nic.id]
  delete_os_disk_on_termination = "true"

  storage_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  storage_os_disk {
    name              = "${var.prefix}-${var.workshop-prefix}-osdisk"
    managed_disk_type = "Standard_LRS"
    caching           = "ReadWrite"
    create_option     = "FromImage"
  }

  os_profile {
    computer_name  = "${var.prefix}-${var.workshop-prefix}"
    admin_username = var.admin_username
    admin_password = var.admin_password
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  provisioner "file" {
    source      = "files/"
    destination = "/home/${var.admin_username}/"

    connection {
      type     = "ssh"
      user     = var.admin_username
      password = var.admin_password
      host     = azurerm_public_ip.vault-pip.fqdn
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod -R +x /home/${var.admin_username}/*",
      "sleep 30",
      "MYSQL_HOST=${var.prefix}-${var.workshop-prefix}-mysql-server /home/${var.admin_username}/setup.sh",
    ]

    connection {
      type     = "ssh"
      user     = var.admin_username
      password = var.admin_password
      host     = azurerm_public_ip.vault-pip.fqdn
    }
  }
}

/* Azure MySQL Database
Vault will manage this database with the database secrets engine.
Terraform can build any type of infrastructure, not just virtual machines.
Azure offers managed MySQL database servers and a whole host of other
resources. Each resource is documented with all the available settings:
https://www.terraform.io/docs/providers/azurerm/r/mysql_server.html */

resource "azurerm_mysql_server" "mysql" {
  name                = "${var.prefix}-${var.workshop-prefix}-mysql-server"
  location            = data.terraform_remote_state.networking.outputs.resource_group_location
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group
  ssl_enforcement     = "Disabled"

  sku {
    name     = "B_Gen5_2"
    capacity = 2
    tier     = "Basic"
    family   = "Gen5"
  }

  storage_profile {
    storage_mb            = 5120
    backup_retention_days = 7
    geo_redundant_backup  = "Disabled"
  }

  administrator_login          = var.admin_username
  administrator_login_password = var.admin_password
  version                      = "5.7"
}

/* This is a sample database that we'll populate with data from our app.
With Terraform, everything is Infrastructure as Code. No more manual steps,
aging runbooks, tribal knowledge or outdated wiki instructions. Terraform
is your executable documentation, and it will build infrastructure correctly
every time. */

resource "azurerm_mysql_database" "wsmysqldatabase" {
  name                = "wsmysqldatabase"
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group
  server_name         = azurerm_mysql_server.mysql.name
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
}

/* Public IP addresses are not generated until they are attached to an object.
So we use a 'data source' here to fetch it once its available. Then we can
provide the public IP address to the next resource for allowing firewall
access to our database. */

data "azurerm_public_ip" "vault-pip" {
  name                = azurerm_public_ip.vault-pip.name
  depends_on          = [azurerm_virtual_machine.vault]
  resource_group_name = azurerm_virtual_machine.vault.resource_group_name
}

/* Allows the Linux VM to connect to the MySQL database, using the IP address
from the data source above. */

resource "azurerm_mysql_firewall_rule" "vault-mysql" {
  name                = "vault-mysql"
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group
  server_name         = azurerm_mysql_server.mysql.name
  start_ip_address    = data.azurerm_public_ip.vault-pip.ip_address
  end_ip_address      = data.azurerm_public_ip.vault-pip.ip_address
}

