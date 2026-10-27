output "node_name" {
  description = "Hostname of the control-plane node."
  value       = proxmox_virtual_environment_container.this.initialization[0].hostname
}

output "vm_id" {
  description = "Proxmox VMID of the control-plane container."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "ip_address" {
  description = "IPv4 address of the control plane."
  value       = var.ip_address
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
