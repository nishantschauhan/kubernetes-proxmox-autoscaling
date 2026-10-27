output "node_name" { value = proxmox_virtual_environment_vm.node.name }
output "ip_address" { value = var.ip_address }
output "vm_id" { value = proxmox_virtual_environment_vm.node.vm_id }
