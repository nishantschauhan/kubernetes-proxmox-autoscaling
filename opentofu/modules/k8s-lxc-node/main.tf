# ============================================================================
# modules/k8s-lxc-node/main.tf — one Kubernetes worker as an LXC container
# ============================================================================
# Read this side by side with modules/k8s-vm-node/main.tf. Same inputs, same
# outputs, different mechanism. That symmetry is what allows the thesis to
# attribute measured differences to the substrate rather than to the code.
#
# THE KEY ASYMMETRY (report this in Chapter 5):
# A QEMU VM boots with a cloud-init drive attached and configures itself
# unattended. An LXC container has no such drive. So this module bootstraps
# in two stages:
#     1. declarative — the provider sets hostname, IP, and SSH key
#     2. imperative  — a provisioner uploads and runs the join script
# The LXC substrate therefore requires an extra operational step the VM
# substrate does not. That is a finding about implementation complexity.
# ============================================================================

resource "proxmox_virtual_environment_container" "this" {
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = "Thesis worker (LXC) — managed by OpenTofu — do not edit by hand"
  tags        = ["thesis", "lxc"]

  # --- Kubernetes-in-LXC requirements -------------------------------------
  # Proxmox restricts LXC feature flags for non-root@pam tokens: even
  # unprivileged, only `nesting` is settable — keyctl/fuse are root-only
  # (HTTP 403 otherwise). Testing K3s without them.
  unprivileged = true

  features {
    nesting = true # containers inside this container
  }

  cpu { cores = var.cores }
  memory {
    dedicated = var.memory_mb
    swap      = 0 # Kubernetes requires swap off
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.disk_gb
  }

  operating_system {
    template_file_id = var.lxc_template_file_id
    type             = "ubuntu"
  }

  # --- Stage 1: declarative identity, network, access ---------------------
  initialization {
    hostname = var.node_name

    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.netmask}"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  started       = true
  start_on_boot = true

  # --- Stage 2: imperative bootstrap --------------------------------------
  connection {
    type        = "ssh"
    user        = "root"
    host        = var.ip_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content     = var.bootstrap_script
    destination = "/tmp/join-cluster.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join-cluster.sh",
      "/tmp/join-cluster.sh 2>&1 | tee /var/log/thesis-bootstrap.log",
    ]
  }

  # Proxmox's API doesn't return initialization/operating_system on read (the
  # SSH key and root password are write-only), so any tofu import of this
  # resource type shows a permanent false diff here that would otherwise
  # force a pointless destroy/recreate on every apply. These are creation-time
  # only anyway — changing them intentionally should replace the resource via
  # a new count index, not an in-place mutation.
  lifecycle {
    ignore_changes = [initialization[0].user_account, operating_system]
  }
}
