# ============================================================================
# modules/k8s-control-plane/main.tf — the K3s server the workers join
# ============================================================================
# OpenTofu in this repo used to provision only WORKER nodes, on the assumption
# that a control plane already existed (built by hand, see
# scripts/bootstrap-control-plane.sh + docs/HARDWARE-DAY.md Gate 4). On a
# restricted account with API-token-only access and no host shell, that manual
# step isn't possible, so this module does the same job through the Proxmox
# API + SSH instead:
#   1. Create the LXC container (same mechanism as modules/k8s-lxc-node).
#   2. Upload and run a K3s *server* bootstrap script over SSH.
#   3. SSH back in to read /root/node-token, so the value can flow straight
#      into the workers' bootstrap_vars in the same `tofu apply` — no manual
#      copy-paste into tfvars.
# ============================================================================

resource "proxmox_virtual_environment_container" "this" {
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = "Thesis K3s control plane — managed by OpenTofu — do not edit by hand"
  tags        = ["thesis", "control-plane"]

  # Proxmox restricts LXC feature flags for non-root@pam tokens: even
  # unprivileged, only `nesting` is settable — keyctl/fuse are root-only
  # (HTTP 403 otherwise). Testing K3s without them; add back if a restricted
  # admin ever grants the Sys.Modify permission needed for the other two.
  unprivileged = true

  features {
    nesting = true
  }

  cpu { cores = var.cores }
  memory {
    dedicated = var.memory_mb
    swap      = 0
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.disk_gb
  }

  operating_system {
    template_file_id = var.lxc_template_file_id
    type             = "ubuntu"
  }

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

  connection {
    type        = "ssh"
    user        = "root"
    host        = var.ip_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/../../../cloud-init/k3s-control-lxc.sh", {
      ip_address   = var.ip_address
      k3s_version  = var.k3s_version
      cluster_cidr = var.cluster_cidr
    })
    destination = "/tmp/bootstrap-control-plane.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap-control-plane.sh",
      "/tmp/bootstrap-control-plane.sh 2>&1 | tee -a /var/log/thesis-bootstrap.log",
    ]
  }

  # See modules/k8s-lxc-node/main.tf for why: Proxmox's API doesn't return
  # initialization/operating_system on read, so an import always shows a
  # false diff there.
  lifecycle {
    ignore_changes = [initialization[0].user_account, operating_system]
  }
}

# ---------------------------------------------------------------------------
# Pull the node-token back out over SSH once the server is up, so it can be
# wired directly into the workers' join config in the same apply.
# ---------------------------------------------------------------------------
resource "terraform_data" "fetch_token" {
  depends_on = [proxmox_virtual_environment_container.this]

  triggers_replace = [proxmox_virtual_environment_container.this.id]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      mkdir -p "${path.root}/.generated"
      ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -i "${pathexpand(var.ssh_private_key_path)}" \
          root@${var.ip_address} "cat /root/node-token" \
          > "${path.root}/.generated/k3s-token-${var.vm_id}"
    EOT
  }
}

data "local_file" "token" {
  depends_on = [terraform_data.fetch_token]
  filename   = "${path.root}/.generated/k3s-token-${var.vm_id}"
}
