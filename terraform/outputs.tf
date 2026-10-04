output "vpc_id" {
  description = "ID of the lab VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, indexed by AZ."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, indexed by AZ."
  value       = module.network.private_subnet_ids
}

output "edge_public_ip" {
  description = "Public IPv4 of edge-01 (EIP or auto-assigned)."
  value       = local.edge_public_ip
}

output "edge_private_ip" {
  description = "Private IPv4 address of edge-01."
  value       = module.vps.edge_private_ip
}

output "edge_instance_id" {
  description = "EC2 instance ID of edge-01."
  value       = module.vps.edge_instance_id
}

output "edge_security_group_id" {
  description = "Security group ID attached to edge-01."
  value       = module.firewall.edge_security_group_id
}

output "node_private_ips" {
  description = "Map of node hostnames (node-01..03) to their private IPv4 addresses."
  value       = module.vps.node_private_ips
}

output "node_instance_ids" {
  description = "Map of node hostnames (node-01..03) to their EC2 instance IDs."
  value       = module.vps.node_instance_ids
}

output "nodes_security_group_id" {
  description = "Security group ID attached to the Kubernetes nodes."
  value       = module.firewall.nodes_security_group_id
}

output "ssh_command_edge" {
  description = "Convenience SSH command to reach edge-01."
  value       = "ssh ubuntu@${local.edge_public_ip}"
}

output "ssh_command_node_via_edge" {
  description = "Convenience SSH command (ProxyJump via edge-01) to reach any node."
  value = {
    for name, ip in module.vps.node_private_ips :
    name => "ssh -J ubuntu@${local.edge_public_ip} ubuntu@${ip}"
  }
}

output "ansible_inventory_yaml" {
  description = "Ansible-compatible YAML inventory built from the deployed hosts."
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    cluster_name              = var.cluster_name
    environment               = var.environment
    edge_public_ip            = local.edge_public_ip
    node_01_private_ip        = module.vps.node_private_ips["node-01"]
    node_02_private_ip        = module.vps.node_private_ips["node-02"]
    node_03_private_ip        = module.vps.node_private_ips["node-03"]
    vpc_cidr                  = var.vpc_cidr
    public_subnet_cidrs       = var.public_subnet_cidrs
    private_subnet_cidrs      = var.private_subnet_cidrs
    kubernetes_pod_subnet     = var.kubernetes_pod_subnet
    kubernetes_service_subnet = var.kubernetes_service_subnet
    enable_dns                = var.enable_dns
    dns_zone                  = var.dns_zone
    dns_subdomain             = var.dns_subdomain
  })
}