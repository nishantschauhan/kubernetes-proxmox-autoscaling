# ============================================================================
# main.tf — Wires the matrix configuration to the right node module
# ============================================================================
# The 2x2 matrix is expressed here. `active_config` selects one cell:
#
#   config-a : kubeadm  + VM        config-b : kubeadm + LXC
#   config-c : K3s      + VM        config-d : K3s     + LXC
#
# Exactly ONE substrate module runs per apply. Only the values change between
# cells — never the module code — which is what keeps the comparison fair.
# ============================================================================

locals {
  # Decode the active cell into its two factors
  config_map = {
    "config-a" = { distro = "kubeadm", substrate = "vm" }
    "config-b" = { distro = "kubeadm", substrate = "lxc" }
    "config-c" = { distro = "k3s", substrate = "vm" }
    "config-d" = { distro = "k3s", substrate = "lxc" }
  }

  distro    = local.config_map[var.active_config].distro
  substrate = local.config_map[var.active_config].substrate

  is_vm  = local.substrate == "vm"
  is_lxc = local.substrate == "lxc"

  # Pick the matching bootstrap file for this cell. Both VM and LXC paths use
  # a plain SSH-uploaded script — see cloud-init/k3s-vm-ssh.sh for why the VM
  # path is no longer a declarative cloud-init snippet.
  vm_bootstrap_script  = "${path.module}/../cloud-init/${local.distro}-vm-ssh.sh"
  lxc_bootstrap_script = "${path.module}/../cloud-init/${local.distro}-lxc.sh"

  # When OpenTofu manages the control plane, pull its endpoint/token(s)
  # straight from whichever distro's module is active instead of the
  # manually-supplied variables — no copy-paste into tfvars required.
  control_plane_endpoint = var.manage_control_plane ? (
    local.distro == "k3s" ? module.control_plane_k3s[0].endpoint : module.control_plane_kubeadm[0].endpoint
  ) : var.k8s_control_plane_endpoint

  control_plane_k3s_token = (var.manage_control_plane && local.distro == "k3s") ? module.control_plane_k3s[0].k3s_token : var.k3s_token

  control_plane_kubeadm_token   = (var.manage_control_plane && local.distro == "kubeadm") ? module.control_plane_kubeadm[0].join_token : var.kubeadm_join_token
  control_plane_kubeadm_ca_hash = (var.manage_control_plane && local.distro == "kubeadm") ? module.control_plane_kubeadm[0].ca_cert_hash : var.kubeadm_ca_cert_hash

  # Values substituted into the bootstrap template at render time
  bootstrap_vars = {
    control_plane_endpoint = local.control_plane_endpoint
    kubeadm_token          = local.control_plane_kubeadm_token
    kubeadm_ca_hash        = local.control_plane_kubeadm_ca_hash
    k3s_token              = local.control_plane_k3s_token
    k3s_version            = var.k3s_version
    k8s_minor_version      = var.k8s_minor_version
    ssh_public_key         = var.ssh_public_key
  }
}

# ---------------------------------------------------------------------------
# Control plane — shared infrastructure, not one of the four matrix cells.
# Exactly one of these runs, matching the active cell's distro. Set
# manage_control_plane = false and supply k8s_control_plane_endpoint plus the
# matching join credentials yourself to use an externally-managed one instead.
# ---------------------------------------------------------------------------
module "control_plane_k3s" {
  source = "./modules/k8s-control-plane"
  count  = (var.manage_control_plane && local.distro == "k3s") ? 1 : 0

  proxmox_node = var.proxmox_node
  vm_id        = var.control_plane_vm_id

  lxc_template_file_id = var.lxc_template_file_id
  storage_pool         = var.storage_pool
  network_bridge       = var.network_bridge

  cores     = var.control_plane_cores
  memory_mb = var.control_plane_memory_mb
  disk_gb   = var.control_plane_disk_gb

  ip_address = "${var.node_ip_base}.${var.control_plane_ip_offset}"
  netmask    = var.network_netmask
  gateway    = var.network_gateway

  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  k3s_version  = var.k3s_version
  cluster_cidr = var.pod_cluster_cidr
}

# Runs on a VM, not LXC — see cloud-init/kubeadm-control-vm-ssh.sh: nested
# containers inside an unprivileged LXC cannot bind listening sockets at all
# (kernel/namespace restriction, reproduced directly with `nc -l`), which
# kubeadm's per-component static-pod architecture needs and K3s's
# single-binary control plane never triggers. modules/k8s-control-plane-kubeadm
# (the LXC version) is kept for reference/if elevated Proxmox permissions
# ever become available, but is no longer wired in here.
module "control_plane_kubeadm" {
  source = "./modules/k8s-control-plane-kubeadm-vm"
  count  = (var.manage_control_plane && local.distro == "kubeadm") ? 1 : 0

  proxmox_node   = var.proxmox_node
  vm_id          = var.control_plane_vm_id
  template_vm_id = var.vm_template_id

  storage_pool   = var.storage_pool
  network_bridge = var.network_bridge

  cores     = var.control_plane_cores
  memory_mb = var.control_plane_memory_mb
  disk_gb   = var.control_plane_disk_gb

  ip_address = "${var.node_ip_base}.${var.control_plane_ip_offset}"
  netmask    = var.network_netmask
  gateway    = var.network_gateway

  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  k8s_minor_version = var.k8s_minor_version
  pod_cidr          = var.pod_cluster_cidr
}

# ---------------------------------------------------------------------------
# VM-substrate worker nodes (config-a, config-c)
#
# NOTE: originally a declarative cloud-init snippet upload. Proxmox's REST
# API has no endpoint to write snippets (filesystem/SSH access to the host
# only), which a restricted API-token account lacks — see
# cloud-init/k3s-vm-ssh.sh. So this now uses the same SSH-uploaded-script
# mechanism as the LXC path below; the VM still pays for a full OS boot, but
# the declarative-vs-imperative delivery asymmetry no longer holds here.
# ---------------------------------------------------------------------------
module "vm_workers" {
  source = "./modules/k8s-vm-node"
  count  = local.is_vm ? var.worker_count : 0

  node_name    = "${var.active_config}-w${count.index}"
  proxmox_node = var.proxmox_node
  vm_id        = var.vmid_base + count.index

  template_vm_id = var.vm_template_id
  storage_pool   = var.storage_pool
  network_bridge = var.network_bridge

  cores     = var.node_cores
  memory_mb = var.node_memory_mb
  disk_gb   = var.node_disk_gb

  ip_address = "${var.node_ip_base}.${var.node_ip_offset + count.index}"
  netmask    = var.network_netmask
  gateway    = var.network_gateway

  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  bootstrap_script = templatefile(local.vm_bootstrap_script, merge(local.bootstrap_vars, {
    hostname = "${var.active_config}-w${count.index}"
  }))
}

# ---------------------------------------------------------------------------
# LXC-substrate worker nodes (config-b, config-d)
#
# NOTE: LXC containers do NOT consume cloud-init user-data the way VMs do.
# The provider sets hostname / IP / SSH key natively, and the join is then
# executed over SSH by a provisioner. This used to be a real VM/LXC asymmetry;
# now that the VM path above also bootstraps via SSH (access-control, not
# design), the remaining difference is just VM vs. LXC boot cost.
# ---------------------------------------------------------------------------
module "lxc_workers" {
  source = "./modules/k8s-lxc-node"
  count  = local.is_lxc ? var.worker_count : 0

  node_name    = "${var.active_config}-w${count.index}"
  proxmox_node = var.proxmox_node
  vm_id        = var.vmid_base + count.index

  lxc_template_file_id = var.lxc_template_file_id
  storage_pool         = var.storage_pool
  network_bridge       = var.network_bridge

  cores     = var.node_cores
  memory_mb = var.node_memory_mb
  disk_gb   = var.node_disk_gb

  ip_address = "${var.node_ip_base}.${var.node_ip_offset + count.index}"
  netmask    = var.network_netmask
  gateway    = var.network_gateway

  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  bootstrap_script = templatefile(local.lxc_bootstrap_script, merge(local.bootstrap_vars, {
    hostname = "${var.active_config}-w${count.index}"
  }))
}
