output "edge_security_group_id" {
  description = "ID of the edge/bastion security group."
  value       = aws_security_group.edge_bastion.id
}

output "nodes_security_group_id" {
  description = "ID of the Kubernetes nodes security group."
  value       = aws_security_group.nodes.id
}