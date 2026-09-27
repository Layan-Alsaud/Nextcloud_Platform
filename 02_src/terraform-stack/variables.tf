variable "project_name" {
  description = "Short name used as a prefix for all resources"
  type        = string
  default     = "nextcloud"
}

variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "denmarkeast"
} 

variable "resource_group_name" {
  description = "Name of the resource group that holds everything"
  type        = string
  default     = "nextcloud-project"
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_address_prefix" {
  description = "Address prefix for the subnet inside the VNet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_D2ls_v6"  
}

variable "admin_username" {
  description = "Login username for the VM"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to local SSH public key file"
  type        = string
  default     = "./ssh-keys/ssh_key.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used to connect to the VM"
  type        = string
  default     = "./ssh-keys/ssh_key"
}

variable "admin_source_ip" {
  description = "The public IP that is allowed to SSH into the VM"
  type        = string
}