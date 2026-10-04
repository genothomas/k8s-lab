data "cloudflare_zone" "this" {
  name = var.dns_zone
}

resource "cloudflare_record" "edge" {
  zone_id = data.cloudflare_zone.this.id
  name    = var.dns_subdomain
  type    = "A"
  content = var.edge_public_ip
  proxied = false
  ttl     = 1
  comment = "Managed by k8s-lab Terraform — points at edge-01 public IP."
}

resource "cloudflare_record" "edge_wildcard" {
  zone_id = data.cloudflare_zone.this.id
  name    = "*.${var.dns_subdomain}"
  type    = "A"
  content = var.edge_public_ip
  proxied = false
  ttl     = 1
  comment = "Managed by k8s-lab Terraform — wildcard for ${var.dns_subdomain}.${var.dns_zone}."
}