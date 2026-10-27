# ============================================================================
# freebsd-edge.tf — FreeBSD edge gateway (docs/HARDWARE-DAY.md Gate 6/7)
# ============================================================================
# Runs FRRouting (BGP) + HAProxy + PF, per edge/frr.conf, edge/haproxy.cfg,
# edge/pf.conf. See cloud-init/freebsd-edge-vm-ssh.sh for the full bootstrap
# and the topology/backend-discovery adaptations made for this lab network.
#
# WHY THE IMAGE COMES FROM A RELAY INSTEAD OF FREEBSD'S OWN SERVERS DIRECTLY:
# proxmox_virtual_environment_download_file's decompression_algorithm only
# supports gz|lzo|zst|bz2. Every image FreeBSD publishes (release AND
# snapshot builds) is .xz-only — there is no supported format we can pull
# straight from download.freebsd.org with an API-token-only account (no host
# shell to run `xz -d` ourselves, same constraint documented in
# vm-template.tf). freebsd_image_relay_url instead points at a throwaway pod
# in our OWN cluster (manifests are not kept in this repo — it's a one-off
# tool, not part of the architecture) that downloaded the official image and
# re-served it already decompressed over plain HTTP on the lab LAN. Delete
# that pod once this resource has successfully imported the disk.
# ============================================================================

variable "build_edge_gateway" {
  description = "Whether OpenTofu manages the FreeBSD edge gateway VM. False is count-gated (would DESTROY it), so only disable deliberately."
  type        = bool
  default     = true
}

variable "edge_gateway_vm_id" {
  type    = number
  default = 910
}

variable "edge_gateway_ip_offset" {
  description = "Last octet of the gateway's static IP (node_ip_base.X). Distinct from the control plane (151) and every worker offset (160+)."
  type        = number
  default     = 230
}

variable "freebsd_image_relay_url" {
  description = "URL of the already-decompressed FreeBSD qcow2, served by the one-off in-cluster relay pod (see note above). Fill in per-run: http://<any-node-ip>:30880/freebsd.qcow2. No default needed while build_edge_gateway=false (see production.tfvars)."
  type        = string
  default     = ""
}

variable "proxmox_mgmt_ip" {
  description = "Proxmox host's own management IP (pf.conf's proxmox_mgmt macro) — the numeric address, since PF firewall rules should not depend on the guest's own DNS resolution for a security-critical match."
  type        = string
  default     = "192.168.67.209"
}

locals {
  edge_gateway_ip = "${var.node_ip_base}.${var.edge_gateway_ip_offset}"
}

resource "proxmox_virtual_environment_download_file" "freebsd_cloud_image" {
  count = var.build_edge_gateway ? 1 : 0

  node_name    = var.proxmox_node
  content_type = "import"
  datastore_id = "local"
  url          = var.freebsd_image_relay_url
  file_name    = "freebsd-14.5-release-amd64-basic-cloudinit.qcow2"
  overwrite    = true
  # The relay pod's Python http.server can take a while to hand off 2.6GB
  # over the lab LAN; default 600s cut it close during testing.
  upload_timeout = 1200
}

resource "proxmox_virtual_environment_vm" "freebsd_edge_gateway" {
  count = var.build_edge_gateway ? 1 : 0

  name        = "thesis-edge-gw"
  node_name   = var.proxmox_node
  vm_id       = var.edge_gateway_vm_id
  description = "FreeBSD edge gateway (FRR+HAProxy+PF) — Gate 6/7"
  tags        = ["thesis", "edge"]

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.freebsd_cloud_image[0].id
    size         = 10
  }

  network_device {
    bridge = var.network_bridge
  }

  # BASIC-CLOUDINIT images ship FreeBSD's own cloud-init (py), which consumes
  # the same NoCloud config-drive Proxmox's `initialization` block generates
  # for the Linux VM nodes — no snippet upload needed here either.
  initialization {
    datastore_id = var.storage_pool

    ip_config {
      ipv4 {
        address = "${local.edge_gateway_ip}/${var.network_netmask}"
        gateway = var.network_gateway
      }
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  agent {
    enabled = false
  }

  # FreeBSD is not a Linux ostype; Proxmox has no dedicated BSD type.
  operating_system {
    type = "other"
  }

  # Added after the first boot attempt came up with no network and no way to
  # see why (qemu-guest-agent is deliberately disabled, same as every other
  # VM node here) — this is how the boot/cloud-init log gets read back via
  # Proxmox's termproxy API.
  serial_device {}
  vga {
    type = "serial0"
  }

  started = true

  connection {
    type        = "ssh"
    user        = "freebsd"
    host        = local.edge_gateway_ip
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/../cloud-init/freebsd-edge-vm-ssh.sh", {
      node_ip_base    = var.node_ip_base
      gateway_ip      = local.edge_gateway_ip
      proxmox_mgmt_ip = var.proxmox_mgmt_ip
    })
    destination = "/tmp/edge-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/edge-bootstrap.sh",
      "sudo /tmp/edge-bootstrap.sh 2>&1 | sudo tee /var/log/thesis-edge-bootstrap.log",
    ]
  }

  lifecycle {
    ignore_changes = [initialization[0].user_account, operating_system]
  }
}

output "edge_gateway_ip" {
  value       = var.build_edge_gateway ? local.edge_gateway_ip : null
  description = "Static IP of the FreeBSD edge gateway — this is the peerAddress for manifests/metallb-config.yaml's BGPPeer."
}
