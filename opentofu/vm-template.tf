# ============================================================================
# vm-template.tf — Builds the Ubuntu cloud-init VM template via the Proxmox
# API alone (no host shell), for accounts with API-token-only access.
# ============================================================================
# docs/HARDWARE-DAY.md Gate 2 assumes a root shell on the Proxmox host
# (qm create / qm importdisk / qm template). A restricted student account has
# no such shell (see the LXC feature-flag / control-plane findings earlier in
# this session), so this does the equivalent through OpenTofu:
#   1. Download the Ubuntu cloud image via the "import" content type
#      (Datacenter -> Storage -> local -> Content -> Import, enabled 2026-09-17).
#   2. Create a VM whose disk is built FROM that imported image
#      (disk.import_from — the API-native equivalent of `qm importdisk`).
#   3. Mark it as a template.
#
# Gated behind build_vm_template (default false) so it never runs as a side
# effect of the normal worker/control-plane apply cycle.
# ============================================================================

variable "build_vm_template" {
  description = "Whether OpenTofu manages the Ubuntu cloud-init VM template. Defaults true once built — false here would DESTROY it (count-gated resource), which is catastrophic if any worker is currently cloned from it. Only set false deliberately (e.g. to rebuild from a different image) after confirming no VM cell depends on it."
  type        = bool
  default     = true
}

variable "vm_template_build_id" {
  description = "VMID to assign the new template."
  type        = number
  default     = 9000
}

variable "vm_template_cloud_image_url" {
  description = "Ubuntu cloud image (qcow2) to import as the template's disk."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  count = var.build_vm_template ? 1 : 0

  node_name    = var.proxmox_node
  content_type = "import"
  datastore_id = "local"
  url          = var.vm_template_cloud_image_url
  # Proxmox's "import" content-type validates the destination filename's
  # extension; the source is qcow2-formatted despite its .img source name, so
  # renaming the destination to .qcow2 is what the API actually requires.
  file_name = "ubuntu-24.04-server-cloudimg-amd64.qcow2"
  overwrite = true
}

resource "proxmox_virtual_environment_vm" "ubuntu_template" {
  count = var.build_vm_template ? 1 : 0

  node_name   = var.proxmox_node
  vm_id       = var.vm_template_build_id
  name        = "ubuntu-2404-cloudinit-template"
  description = "Cloud-init template built via OpenTofu (API-only, no host shell) — do not edit by hand"
  tags        = ["thesis", "template"]

  template = true
  started  = false

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  # qemu-guest-agent is not installed on the official Ubuntu cloud image and
  # we have no host shell to bake it in — see modules/k8s-vm-node/main.tf.
  agent {
    enabled = false
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_image[0].id
    size         = 20
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.storage_pool
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}

output "vm_template_id_built" {
  value       = var.build_vm_template ? proxmox_virtual_environment_vm.ubuntu_template[0].vm_id : null
  description = "Paste this into production.tfvars as vm_template_id once built."
}
