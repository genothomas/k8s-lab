variable "cluster_name" {
  description = "Cluster name used for tag/Name prefixing."
  type        = string
}

variable "environment" {
  description = "Environment label used for tagging."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones (one per public/private subnet pair)."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
}

variable "nat_eni_id" {
  description = "ENI ID for the NAT target. Required when edge_enable_nat = true (edge-01's primary ENI)."
  type        = string
  default     = null
}

variable "edge_enable_nat" {
  description = "When true, skip dedicated NAT and route private RT to nat_eni_id. Must match vps.edge_enable_nat."
  type        = bool
  default     = true
}

variable "nat_ami_id" {
  description = "NAT instance AMI ID. Used only when nat_eni_id is null."
  type        = string
  default     = null
}

variable "nat_instance_type" {
  description = "NAT instance type. Used only when nat_eni_id is null."
  type        = string
  default     = "t4g.nano"
}

variable "nat_ssh_public_key_path" {
  description = "NAT instance SSH public key path. Used only when nat_eni_id is null."
  type        = string
  default     = null
}

variable "nat_ssh_key_name" {
  description = "NAT instance key pair name. Used only when nat_eni_id is null."
  type        = string
  default     = null
}

variable "nat_root_volume_size" {
  description = "NAT instance root EBS volume (GiB). Used only when nat_eni_id is null."
  type        = number
  default     = 20
}

variable "ssh_admin_cidrs" {
  description = "NAT instance SSH (22/tcp) CIDRs. Used only when nat_eni_id is null."
  type        = list(string)
  default     = []
}