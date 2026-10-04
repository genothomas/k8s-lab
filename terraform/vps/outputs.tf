output "edge_instance_id" {
  description = "EC2 instance ID of edge-01."
  value       = aws_instance.edge.id
}

output "edge_private_ip" {
  description = "Private IPv4 of edge-01."
  value       = aws_instance.edge.private_ip
}

output "edge_instance_public_ip" {
  description = "Auto-assigned public IPv4 of edge-01 (use when enable_elastic_ip is false)."
  value       = aws_instance.edge.public_ip
}

output "edge_eip" {
  description = "Elastic IP address of edge-01 (only allocated when enable_elastic_ip is true)."
  value       = var.enable_elastic_ip ? aws_eip.edge[0].public_ip : null
}

output "edge_primary_network_interface_id" {
  description = "Primary ENI ID of edge-01. Used as the NAT route target when edge_enable_nat is true."
  value       = aws_instance.edge.primary_network_interface_id
}

output "node_private_ips" {
  description = "Map node-01..03 → private IPv4."
  value = {
    for name, inst in aws_instance.nodes :
    name => inst.private_ip
  }
}

output "node_instance_ids" {
  description = "Map node-01..03 → EC2 instance ID."
  value = {
    for name, inst in aws_instance.nodes :
    name => inst.id
  }
}