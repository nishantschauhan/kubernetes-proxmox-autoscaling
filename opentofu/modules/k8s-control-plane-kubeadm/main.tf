# ============================================================================
# modules/k8s-control-plane-kubeadm/main.tf — the kubeadm server workers join
# ============================================================================
# Mirrors modules/k8s-control-plane (K3s): create the LXC via the API, run a
# bootstrap script over SSH, then SSH back in to read the values workers need
# — here that's TWO values (join token + CA cert hash) instead of one.
# ============================================================================

resource "proxmox_virtual_environment_container" "this" {
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = "Thesis kubeadm control plane — managed by OpenTofu — do not edit by hand"
  tags        = ["thesis", "control-plane"]

  # Proxmox restricts LXC feature flags for non-root@pam tokens: even
  # unprivileged, only `nesting` is settable — keyctl/fuse are root-only.
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
    content = templatefile("${path.module}/../../../cloud-init/kubeadm-control-lxc.sh", {
      ip_address        = var.ip_address
      k8s_minor_version = var.k8s_minor_version
      pod_cidr          = var.pod_cidr
    })
    destination = "/tmp/bootstrap-control-plane.sh"
  }

  # kubeadm init pulls several container images and starts etcd/apiserver/
  # controller-manager/scheduler — expect this to take noticeably longer
  # than the K3s control plane's single-binary bootstrap.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap-control-plane.sh",
      "/tmp/bootstrap-control-plane.sh 2>&1 | tee -a /var/log/thesis-bootstrap.log",
    ]
  }

  lifecycle {
    ignore_changes = [initialization[0].user_account, operating_system]
  }
}

# ---------------------------------------------------------------------------
# Pull the join token + CA cert hash back over SSH once the server is up.
# ---------------------------------------------------------------------------
resource "terraform_data" "fetch_join_info" {
  depends_on = [proxmox_virtual_environment_container.this]

  triggers_replace = [proxmox_virtual_environment_container.this.id]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      mkdir -p "${path.root}/.generated"
      ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -i "${pathexpand(var.ssh_private_key_path)}" \
          root@${var.ip_address} "cat /root/join-info" \
          > "${path.root}/.generated/kubeadm-join-info-${var.vm_id}"
    EOT
  }
}

data "local_file" "join_info" {
  depends_on = [terraform_data.fetch_join_info]
  filename   = "${path.root}/.generated/kubeadm-join-info-${var.vm_id}"
}

locals {
  # File has exactly two lines: token, then CA hash (see kubeadm-control-lxc.sh)
  join_info_lines = split("\n", trimspace(data.local_file.join_info.content))
}
