variable "cluster_name" {
  description = "Cluster identity used as a tag/name prefix (e.g. nexus)."
  type        = string
  default     = "nexus"
}

variable "environment" {
  description = "Environment label used as a tag (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zones" {
  description = "AZs (one per public/private subnet pair). Validation enforces length match."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]

  validation {
    condition     = length(var.availability_zones) == length(var.public_subnet_cidrs) && length(var.availability_zones) == length(var.private_subnet_cidrs)
    error_message = "availability_zones, public_subnet_cidrs, and private_subnet_cidrs must all have the same length."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ. First subnet hosts HAProxy/bastion + NAT."
  type        = list(string)
  default     = ["10.40.0.0/24", "10.40.1.0/24", "10.40.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ. One node per subnet."
  type        = list(string)
  default     = ["10.40.10.0/24", "10.40.11.0/24", "10.40.12.0/24"]
}

variable "kubernetes_pod_subnet" {
  description = "Pod CIDR (kubeadm + Cilium). Must not overlap vpc_cidr."
  type        = string
  default     = "10.42.0.0/16"
}

variable "kubernetes_service_subnet" {
  description = "Service CIDR (kube-apiserver VIP). Must not overlap vpc_cidr or pod_subnet."
  type        = string
  default     = "10.43.0.0/16"
}

variable "edge_public_key_path" {
  description = "Local path to edge-01 public key (file())."
  type        = string
  default     = "~/.ssh/nexus_edge.pub"
}

variable "nodes_public_key_path" {
  description = "Local path to nodes public key (file())."
  type        = string
  default     = "~/.ssh/nexus_nodes.pub"
}

variable "ssh_admin_cidrs" {
  description = "SSH (22/tcp) ingress on edge bastion. Set to your IP/32."
  type        = list(string)
  default     = ["129.154.251.111/32"]
}

variable "kubernetes_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API on TCP 6443 via HAProxy. Public by design (HAProxy is the LB)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_allowed_cidrs" {
  description = "CIDRs allowed to reach TCP 80/443 on the HAProxy front. Public by design."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ami_id_override" {
  description = "Optional AMI ID. null → dynamic Ubuntu 24.04 LTS lookup."
  type        = string
  default     = null
}

variable "edge_instance_type" {
  description = "EC2 instance type for edge-01."
  type        = string
  default     = "t3a.small"
}

variable "edge_enable_nat" {
  description = "When true, edge-01 is the NAT source (ip_forward + MASQUERADE) and the dedicated NAT instance is skipped. Default true for lab minimalism."
  type        = bool
  default     = true
}

variable "nat_instance_type" {
  description = "NAT instance type. Used only when edge_enable_nat is false."
  type        = string
  default     = "t4g.nano"
}

variable "node_instance_type" {
  description = "EC2 instance type for the Kubernetes control-plane+worker nodes."
  type        = string
  default     = "t3a.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for all instances."
  type        = number
  default     = 30
}

variable "enable_elastic_ip" {
  description = "Allocate an EIP for edge-01. Off by default for disposability."
  type        = bool
  default     = false
}

variable "enable_dns" {
  description = "Manage Cloudflare DNS records. Requires dns_zone to exist in CF."
  type        = bool
  default     = false
}

variable "dns_zone" {
  description = "Cloudflare zone name. Used when enable_dns is true."
  type        = string
  default     = "example.com"
}

variable "dns_subdomain" {
  description = "Subdomain prefix. Creates <sub>.<zone> + *.<sub>.<zone>."
  type        = string
  default     = "edge"
}