# ============================================================================
# outputs.tf — Values printed after apply, and consumed by the measurement
# scripts. `tofu output -json` is how scripts/ learn what was provisioned.
# ============================================================================

output "active_config" {
  description = "Which matrix cell is currently deployed"
  value       = var.active_config
}

output "distribution" {
  description = "Kubernetes distribution for the active cell"
  value       = local.distro
}

output "substrate" {
  description = "Compute substrate for the active cell"
  value       = local.substrate
}

output "worker_count" {
  description = "Number of worker nodes currently declared"
  value       = var.worker_count
}

output "worker_names" {
  description = "Hostnames of provisioned workers (matches Kubernetes node names)"
  value       = local.is_vm ? module.vm_workers[*].node_name : module.lxc_workers[*].node_name
}

output "worker_ips" {
  description = "IP addresses of provisioned workers"
  value       = local.is_vm ? module.vm_workers[*].ip_address : module.lxc_workers[*].ip_address
}
