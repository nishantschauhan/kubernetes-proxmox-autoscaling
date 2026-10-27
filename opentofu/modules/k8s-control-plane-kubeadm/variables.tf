# ============================================================================
# modules/k8s-control-plane-kubeadm/variables.tf
# ============================================================================
# Shared infrastructure for config-a/config-b — not itself a matrix cell.
# ============================================================================

variable "node_name" {
  type    = string
  default = "kubeadm-control"
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

variable "k8s_minor_version" {
  description = "Kubernetes minor version stream, e.g. v1.31 (used for the pkgs.k8s.io apt repo)."
  type        = string
}

variable "pod_cidr" {
  description = "Pod network CIDR for the kubeadm cluster (must match the Flannel manifest's default, 10.244.0.0/16)."
  type        = string
  default     = "10.244.0.0/16"
}
