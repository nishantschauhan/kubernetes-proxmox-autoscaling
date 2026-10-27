output "node_name" {
  value = proxmox_virtual_environment_vm.node.name
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.node.vm_id
}

output "ip_address" {
  value = var.ip_address
}

output "endpoint" {
  description = "host:port workers use to join, e.g. 192.168.67.151:6443."
  value       = "${var.ip_address}:6443"
}

output "join_token" {
  description = "kubeadm bootstrap token, extracted from the control plane over SSH."
  value       = local.join_info_lines[0]
  sensitive   = true
}

output "ca_cert_hash" {
  description = "kubeadm discovery CA cert hash (no sha256: prefix), extracted over SSH."
  value       = local.join_info_lines[1]
  sensitive   = true
}
