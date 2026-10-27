variable "node_name" { type = string }
variable "proxmox_node" { type = string }
variable "vm_id" { type = number }
variable "template_vm_id" { type = number }
variable "storage_pool" { type = string }
variable "network_bridge" { type = string }
variable "cores" { type = number }
variable "memory_mb" { type = number }
variable "disk_gb" { type = number }
variable "ip_address" { type = string }
variable "netmask" { type = number }
variable "gateway" { type = string }

variable "ssh_public_key" {
  description = "Injected via cloud-init's native user_account block (no snippet needed)."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Used by the bootstrap provisioner to connect to the VM's own guest IP."
  type        = string
}

variable "bootstrap_script" {
  description = "Rendered join script, uploaded and executed over SSH (same mechanism as modules/k8s-lxc-node)."
  type        = string
}
