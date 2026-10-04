output "fqdn_edge" {
  description = "FQDN pointing at edge-01."
  value       = "${var.dns_subdomain}.${var.dns_zone}"
}

output "fqdn_wildcard" {
  description = "Wildcard FQDN under the edge subdomain."
  value       = "*.${var.dns_subdomain}.${var.dns_zone}"
}

output "cloudflare_zone_id" {
  description = "ID of the Cloudflare zone the records are written to."
  value       = data.cloudflare_zone.this.id
}