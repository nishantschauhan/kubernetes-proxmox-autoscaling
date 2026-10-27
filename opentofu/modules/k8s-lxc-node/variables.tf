# ============================================================================
# modules/k8s-lxc-node/variables.tf
# ============================================================================
# These inputs deliberately MIRROR modules/k8s-vm-node/variables.tf, so that
# main.tf can call either module with the same arguments. The only differences
# are the two at the bottom: LXC needs SSH details for its bootstrap
# provisioner, where the VM path uses a cloud-init file instead.
# ============================================================================

variable "node_name" { type = string }    # hostname, e.g. config-b-w0
variable "proxmox_node" { type = string } # Proxmox host name, e.g. "pve"
variable "vm_id" { type = number }        # numeric VMID

variable "lxc_template_file_id" {
  description = "e.g. local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  type        = string
}

variable "storage_pool" { type = string }
variable "network_bridge" { type = string }

# Sizing — MUST match the VM module values or the comparison is unfair
variable "cores" { type = number }
variable "memory_mb" { type = number }
variable "disk_gb" { type = number }

# Static addressing
variable "ip_address" { type = string }
variable "netmask" { type = number }
variable "gateway" { type = string }

# --- LXC-only inputs -------------------------------------------------------
# The VM module receives cloud_init_file_id here instead. LXC has no
# cloud-init drive, so it needs SSH access to run its bootstrap.
variable "ssh_public_key" {
  description = "Injected for root login."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Used by the bootstrap provisioner to connect."
  type        = string
}

variable "bootstrap_script" {
  description = "Rendered join script, uploaded and executed over SSH."
  type        = string
}

variable "root_password" {
  description = "LXC requires a root password to be set at creation."
  type        = string
  sensitive   = true
  default     = "thesis-lab-only"
}
