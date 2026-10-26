# Printed after `terraform apply`. The public IP is the one value you have to
# carry by hand into Jenkins (as the `azure-vm-ip` credential).

output "public_ip" {
  description = "The VM's public IP. Put this in the Jenkins credential `azure-vm-ip`."
  value       = azurerm_public_ip.app.ip_address
}

output "app_url" {
  description = "Open this in a browser once the pipeline has deployed. Screenshot it for the report."
  value       = "http://${azurerm_public_ip.app.ip_address}/"
}

output "ssh_command" {
  description = "Copy-paste to log into the VM."
  value       = "ssh -i ~/.ssh/mandi_azure ${var.admin_username}@${azurerm_public_ip.app.ip_address}"
}

output "resource_group" {
  description = "Delete this one group to tear the whole deployment down."
  value       = azurerm_resource_group.main.name
}
