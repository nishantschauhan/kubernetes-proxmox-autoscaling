# ============================================================================
# modules/k8s-control-plane-kubeadm-vm/main.tf — kubeadm control plane on a VM
# ============================================================================
# Mirrors modules/k8s-vm-node (cloud-init injects only an SSH key, bootstrap
# runs imperatively over SSH) plus modules/k8s-control-plane-kubeadm's
# token-fetch pattern (here: TWO values, join token + CA cert hash).
# ============================================================================

resource "proxmox_virtual_environment_vm" "node" {
  name      = var.node_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_gb
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.storage_pool

    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.netmask}"
        gateway = var.gateway
      }
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  # qemu-guest-agent is not installed on the official Ubuntu cloud image and
  # we have no host shell to bake it in — see modules/k8s-vm-node/main.tf.
  agent {
    enabled = false
  }

  started = true

  # kubeadm init pulls several images and starts etcd/apiserver/
  # controller-manager/scheduler as separate containers — slower than the
  # K3s control plane's single-binary bootstrap, and slower still than an
  # LXC boot (full kernel + cloud-init first-run).
  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = var.ip_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/../../../cloud-init/kubeadm-control-vm-ssh.sh", {
      ip_address        = var.ip_address
      k8s_minor_version = var.k8s_minor_version
      pod_cidr          = var.pod_cidr
    })
    destination = "/tmp/bootstrap-control-plane.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap-control-plane.sh",
      "sudo /tmp/bootstrap-control-plane.sh 2>&1 | sudo tee /var/log/thesis-bootstrap.log",
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
  depends_on = [proxmox_virtual_environment_vm.node]

  triggers_replace = [proxmox_virtual_environment_vm.node.id]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      mkdir -p "${path.root}/.generated"
      ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -i "${pathexpand(var.ssh_private_key_path)}" \
          ubuntu@${var.ip_address} "cat /tmp/join-info" \
          > "${path.root}/.generated/kubeadm-vm-join-info-${var.vm_id}"
    EOT
  }
}

data "local_file" "join_info" {
  depends_on = [terraform_data.fetch_join_info]
  filename   = "${path.root}/.generated/kubeadm-vm-join-info-${var.vm_id}"
}

locals {
  join_info_lines = split("\n", trimspace(data.local_file.join_info.content))
}
