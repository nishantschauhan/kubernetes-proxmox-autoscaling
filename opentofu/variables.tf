# ============================================================================
# variables.tf — Every environment-specific value is DECLARED here
# ============================================================================
# This file declares WHAT can vary. It does not set values.
# Values come from laptop.tfvars (development) or production.tfvars (hardware).
#
# THIS IS THE HEART OF THE LAPTOP -> HARDWARE MIGRATION.
# Because nothing below is hardcoded anywhere else in the repo, moving from
# your laptop to the Hof University server is a matter of filling in one
# tfvars file. The modules themselves never change.
# ============================================================================

# ---------------------------------------------------------------------------
# Proxmox connection
# ---------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://10.0.0.10:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token: user@realm!tokenid=uuid. Set via TF_VAR_proxmox_api_token env var."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (true for self-signed lab certificates)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox host (used by the provider for snippet upload)"
  type        = string
  default     = "root"
}

variable "proxmox_node" {
  description = "Name of the Proxmox node as shown in the web UI, e.g. 'pve'"
  type        = string
}

# ---------------------------------------------------------------------------
# Storage and networking — these names differ between laptop and hardware
# ---------------------------------------------------------------------------
variable "storage_pool" {
  description = "Datastore for VM/LXC disks, e.g. 'local-lvm'"
  type        = string
}

variable "snippet_storage" {
  description = "Datastore that has the 'snippets' content type enabled (for cloud-init)"
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Linux bridge for node NICs, e.g. 'vmbr0'"
  type        = string
}

variable "network_gateway" {
  description = "Default gateway for provisioned nodes"
  type        = string
}

variable "network_netmask" {
  description = "CIDR prefix length for node addresses, e.g. 24"
  type        = number
  default     = 24
}

# ---------------------------------------------------------------------------
# Templates — the golden images cloned for each substrate
# ---------------------------------------------------------------------------
variable "vm_template_id" {
  description = "VMID of the Ubuntu cloud-init VM template to clone (VM cells)"
  type        = number
}

variable "lxc_template_file_id" {
  description = "LXC template file id, e.g. 'local:vztmpl/ubuntu-22.04-standard_...tar.zst'"
  type        = string
}

# ---------------------------------------------------------------------------
# Cluster join parameters
# ---------------------------------------------------------------------------
variable "k8s_control_plane_endpoint" {
  description = "Control-plane address:port that new nodes join, e.g. 10.0.0.20:6443"
  type        = string
}

variable "kubeadm_join_token" {
  description = "kubeadm bootstrap token for worker join"
  type        = string
  sensitive   = true
  default     = ""
}

variable "kubeadm_ca_cert_hash" {
  description = "kubeadm discovery CA cert hash (sha256:...)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "k3s_token" {
  description = "K3s node token for agent join. Ignored when manage_control_plane is true — the token is extracted automatically from the OpenTofu-managed control plane instead."
  type        = string
  sensitive   = true
  default     = ""
}

variable "k8s_minor_version" {
  description = "Kubernetes minor version stream for kubeadm cells, e.g. v1.31 (used for the pkgs.k8s.io apt repo in kubeadm-lxc.sh / kubeadm-vm.yaml)."
  type        = string
  default     = "v1.31"
}

variable "k3s_version" {
  description = "K3s version installed on both the control plane and K3s workers (config-c/config-d)."
  type        = string
  default     = "v1.31.4+k3s1"
}

# ---------------------------------------------------------------------------
# Control plane — shared infrastructure for all four cells, not itself a
# matrix cell. Only the K3s path is automated; a kubeadm control plane still
# needs the manual procedure in docs/HARDWARE-DAY.md Gate 4.
# ---------------------------------------------------------------------------
variable "manage_control_plane" {
  description = "Whether OpenTofu creates and bootstraps the K3s control-plane LXC. Set false if a control plane already exists elsewhere and you're supplying k8s_control_plane_endpoint/k3s_token yourself."
  type        = bool
  default     = true
}

variable "control_plane_vm_id" {
  description = "VMID for the OpenTofu-managed control-plane LXC. Must not collide with vmid_base."
  type        = number
  default     = 901
}

variable "control_plane_ip_offset" {
  description = "Last octet of the control plane's static IP (node_ip_base.X)."
  type        = number
  default     = 151
}

variable "control_plane_cores" {
  type    = number
  default = 2
}

variable "control_plane_memory_mb" {
  type    = number
  default = 2048
}

variable "control_plane_disk_gb" {
  type    = number
  default = 20
}

variable "pod_cluster_cidr" {
  description = "Pod network CIDR for the OpenTofu-managed K3s control plane."
  type        = string
  default     = "10.244.0.0/16"
}

# ---------------------------------------------------------------------------
# Node sizing — held IDENTICAL across all four configurations so that the
# comparison isolates distribution and substrate, not resource allocation.
# ---------------------------------------------------------------------------
variable "node_cores" {
  description = "vCPU cores per worker node"
  type        = number
  default     = 2
}

variable "node_memory_mb" {
  description = "RAM per worker node in MB"
  type        = number
  default     = 4096
}

variable "node_disk_gb" {
  description = "Disk size per worker node in GB"
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Experiment selection — which of the four matrix cells to provision
# ---------------------------------------------------------------------------
variable "active_config" {
  description = "Which matrix cell to deploy: config-a | config-b | config-c | config-d"
  type        = string

  validation {
    condition     = contains(["config-a", "config-b", "config-c", "config-d"], var.active_config)
    error_message = "active_config must be one of: config-a, config-b, config-c, config-d."
  }
}

variable "worker_count" {
  description = "Number of worker nodes. The autoscale watcher increments this value."
  type        = number
  default     = 1
}

variable "node_ip_base" {
  description = "First three octets of the node IP range, e.g. '10.0.0'"
  type        = string
}

variable "node_ip_offset" {
  description = "Last octet of the first worker; subsequent workers increment from here"
  type        = number
  default     = 50
}

variable "vmid_base" {
  description = "Starting VMID for provisioned worker nodes"
  type        = number
  default     = 900
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------
variable "ssh_public_key" {
  description = "Public key injected into every node for operator access"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to matching private key, used by the LXC remote-exec provisioner"
  type        = string
  default     = "~/.ssh/id_ed25519"
}
