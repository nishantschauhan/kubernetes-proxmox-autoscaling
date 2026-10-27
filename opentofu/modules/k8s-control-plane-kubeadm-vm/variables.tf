# ============================================================================
# modules/k8s-control-plane-kubeadm-vm/variables.tf
# ============================================================================
# Shared infrastructure for config-a/config-b — not itself a matrix cell.
# Runs on a VM (not LXC): see cloud-init/kubeadm-control-vm-ssh.sh for why —
# nested containers inside an unprivileged LXC cannot bind listening sockets
# at all, which kubeadm's per-component static-pod architecture needs.
# ============================================================================

variable "node_name" {
  type    = string
  default = "kubeadm-control"
}
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
  description = "Injected via cloud-init's native user_account block."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Used by the bootstrap provisioner and the token-fetch step. Connects as 'ubuntu' — root SSH login is disabled on the cloud image."
  type        = string
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
