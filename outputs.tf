output "public_ip_address" {
  description = "The VM's public IP address"
  value       = azurerm_public_ip.main.ip_address
}

output "ssh_command" {
  description = "SSH into the VM"
  value       = "ssh -i ${var.ssh_private_key_path} ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}
