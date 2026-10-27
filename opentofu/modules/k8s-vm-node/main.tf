# ============================================================================
# modules/k8s-vm-node — Provisions ONE Kubernetes worker as a QEMU VM
# ============================================================================
# Used by config-a (kubeadm + VM) and config-c (K3s + VM).
#
# Originally: a full clone of a prepared cloud-init template, configured
# unattended via a declarative cloud-init snippet uploaded to Proxmox's
# "snippets" storage. That upload requires filesystem/SSH access to the
# Proxmox HOST — Proxmox's REST API has no endpoint for it — which a
# restricted API-token account does not have. So this module now mirrors
# modules/k8s-lxc-node instead: cloud-init injects only an SSH key (no
# snippet needed for that alone), then a bootstrap script is uploaded and run
# over SSH to the VM's own guest IP. The VM still pays for a full OS boot —
# that cost is still measured — but the declarative/imperative delivery
# asymmetry the README describes between VM and LXC no longer holds on this
# account. See cloud-init/k3s-vm-ssh.sh for the full explanation.
# ============================================================================

resource "proxmox_virtual_environment_vm" "node" {
  name      = var.node_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  # Full clone (not linked) so each node is independent — important for
  # fair timing measurement, since linked clones share backing storage.
  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "host" # pass through host CPU features for representative performance
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

  # cloud-init supplies only identity/network/SSH access — no snippet needed.
  # The default cloud-init user on the official Ubuntu cloud image is
  # "ubuntu", not "root" (unlike the LXC path, where Proxmox sets up root
  # directly) — see the connection block below.
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

  # qemu-guest-agent is NOT installed on the official Ubuntu cloud image
  # (confirmed: "Unit qemu-guest-agent.service could not be found"), and we
  # have no host shell to bake it into the template. agent.enabled=true made
  # the provider block indefinitely waiting for a handshake that would never
  # come (stuck past 4.5 minutes, heading for the 30-minute create timeout).
  # We already supply static IPs ourselves, so the agent isn't needed.
  agent {
    enabled = false
  }

  started = true

  # A full VM boot (kernel + cloud-init first-boot) is slower to reach SSH
  # than an LXC container sharing the host kernel — that gap is itself part
  # of what this cell measures, not a bug.
  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = var.ip_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    content     = var.bootstrap_script
    destination = "/tmp/join-cluster.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join-cluster.sh",
      "sudo /tmp/join-cluster.sh 2>&1 | sudo tee /var/log/thesis-bootstrap.log",
    ]
  }

  # See modules/k8s-lxc-node/main.tf: Proxmox's API doesn't return
  # initialization/operating_system on read, so an import always shows a
  # false diff there. Also covers the pre-existing "spurious diff on
  # re-apply" concern this lifecycle block used to handle for user_data.
  lifecycle {
    ignore_changes = [initialization[0].user_account, operating_system]
  }
}
