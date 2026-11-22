output "server_floating_ip" {
  description = "IP flottante du nœud serveur (SSH, API Kubernetes, NodePorts)"
  value       = openstack_networking_floatingip_v2.server.address
}

output "server_private_ip" {
  description = "IP privée (port Neutron) du nœud serveur"
  value       = openstack_networking_port_v2.server.all_fixed_ips[0]
}

output "agent_private_ips" {
  description = "IP privées des nœuds agents"
  value       = { for i, p in openstack_networking_port_v2.agent : "${var.prefix}-agent-${i + 1}" => p.all_fixed_ips[0] }
}

output "ssh_server" {
  description = "Commande SSH vers le serveur"
  value       = "ssh ubuntu@${openstack_networking_floatingip_v2.server.address}"
}

output "ssh_agent_example" {
  description = "SSH vers un agent en rebond par le serveur"
  value       = var.agent_count > 0 ? "ssh -J ubuntu@${openstack_networking_floatingip_v2.server.address} ubuntu@${openstack_networking_port_v2.agent[0].all_fixed_ips[0]}" : "aucun agent"
}
