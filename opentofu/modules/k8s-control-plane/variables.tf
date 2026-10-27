# ============================================================================
# modules/k8s-control-plane/variables.tf
# ============================================================================
# This node is shared infrastructure for all four matrix cells — it is not
# itself config-a/b/c/d, so its inputs are deliberately separate from the
# worker modules' sizing/addressing rather than reusing them.
# ============================================================================

variable "node_name" {
  type    = string
  default = "k3s-control"
}
variable "proxmox_node" { type = string }
variable "vm_id" { type = number }

variable "lxc_template_file_id" {
  description = "e.g. local:vztmpl/ubuntu-24.04-standard_...tar.zst"
  type        = string
}

variable "storage_pool" { type = string }
variable "network_bridge" { type = string }

variable "cores" { type = number }
variable "memory_mb" { type = number }
variable "disk_gb" { type = number }

variable "ip_address" { type = string }
variable "netmask" { type = number }
variable "gateway" { type = string }

variable "ssh_public_key" {
  description = "Injected for root login."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Used by the bootstrap provisioner and by the token-fetch step."
  type        = string
}

variable "root_password" {
  description = "LXC requires a root password to be set at creation."
  type        = string
  sensitive   = true
  default     = "thesis-lab-only"
}

variable "k3s_version" {
  description = "K3s version to install on the control plane (must match the workers)."
  type        = string
}

variable "cluster_cidr" {
  description = "Pod network CIDR for the K3s cluster."
  type        = string
  default     = "10.244.0.0/16"
}
