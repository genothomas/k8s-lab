variable "edge_public_ip" {
  description = "Public IPv4 of edge-01 (used as the target for the Cloudflare A record)."
  type        = string
}

variable "dns_zone" {
  description = "Cloudflare zone name (must already exist in your Cloudflare account)."
  type        = string
}

variable "dns_subdomain" {
  description = "Subdomain prefix. Records: <subdomain>.<zone> and *.<subdomain>.<zone>."
  type        = string
}