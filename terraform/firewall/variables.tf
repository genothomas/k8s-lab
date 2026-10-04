variable "cluster_name" {
  description = "Cluster name used for tag/Name prefixing."
  type        = string
}

variable "environment" {
  description = "Environment label used for tagging."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the security groups are created."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Scopes edge ingress ephemeral-port rule to in-VPC reply."
  type        = string
}

variable "ssh_admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22/tcp) on the edge bastion."
  type        = list(string)
}

variable "kubernetes_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API on TCP 6443 via HAProxy."
  type        = list(string)
}

variable "http_allowed_cidrs" {
  description = "CIDRs allowed to reach TCP 80/443 on the HAProxy front."
  type        = list(string)
}