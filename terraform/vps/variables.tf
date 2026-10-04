variable "cluster_name" {
  description = "Cluster name used for tag/Name prefixing."
  type        = string
}

variable "environment" {
  description = "Environment label used for tagging."
  type        = string
}

variable "public_subnet_ids" {
  description = "Map of AZ → public subnet ID."
  type        = map(string)
}

variable "private_subnet_ids" {
  description = "Map of AZ → private subnet ID."
  type        = map(string)
}

variable "edge_sg_id" {
  description = "Security group ID for edge-01."
  type        = string
}

variable "nodes_sg_id" {
  description = "Security group ID for the Kubernetes nodes."
  type        = string
}

variable "edge_public_key_path" {
  description = "Local path to edge-01 public key (file())."
  type        = string
}

variable "nodes_public_key_path" {
  description = "Local path to nodes public key (file())."
  type        = string
}

variable "edge_instance_type" {
  description = "EC2 instance type for edge-01."
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for the Kubernetes nodes."
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
}

variable "ami_id" {
  description = "Resolved AMI ID (Ubuntu 24.04 lookup or override)."
  type        = string
}

variable "enable_elastic_ip" {
  description = "Allocate and associate an Elastic IP for edge-01."
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "AZs; index-aligned with private_subnet_ids for hostname→subnet mapping."
  type        = list(string)
}

variable "edge_enable_nat" {
  description = "When true, edge-01 is the NAT source (source_dest_check disabled, ip_forward + MASQUERADE via user_data)."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "VPC CIDR. Scopes the MASQUERADE rule in edge NAT user_data."
  type        = string
}