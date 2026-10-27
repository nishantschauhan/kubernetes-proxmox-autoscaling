# ============================================================================
# modules/k8s-lxc-node/outputs.tf
# ============================================================================
# Same output names as the VM module, so the root module and the measurement
# scripts consume either substrate identically.
# ============================================================================

output "node_name" {
  description = "Hostname of the provisioned node."
  value       = proxmox_virtual_environment_container.this.initialization[0].hostname
}

output "vm_id" {
  description = "Proxmox VMID."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "ip_address" {
  description = "IPv4 address assigned to the node."
  value       = var.ip_address
}

output "substrate" {
  description = "Substrate identifier, consumed by measurement tooling."
  value       = "lxc"
}
