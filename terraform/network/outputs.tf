output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Map of AZ → public subnet ID."
  value = {
    for az, subnet in aws_subnet.public :
    az => subnet.id
  }
}

output "private_subnet_ids" {
  description = "Map of AZ → private subnet ID."
  value = {
    for az, subnet in aws_subnet.private :
    az => subnet.id
  }
}

output "nat_source" {
  description = "NAT source: \"edge-01\" or \"nat-instance\"."
  value       = local.create_nat ? "nat-instance" : "edge-01"
}

output "nat_instance_id" {
  description = "ID of the NAT EC2 instance. Null when edge-01 is the NAT source."
  value       = local.create_nat ? aws_instance.nat[0].id : null
}

output "nat_eip_public_ip" {
  description = "NAT instance EIP. Null when edge-01 is the NAT source."
  value       = local.create_nat ? aws_eip.nat[0].public_ip : null
}