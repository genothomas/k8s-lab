# Standalone entry point for the Cloudflare DNS records.
#
# The `dns` module is normally wired into the AWS root module, which also
# needs AWS credentials and an applied VPC. The local-VM lab has neither —
# it only needs the two A records in front of the public VPS.
#
# Usage:
#   export CLOUDFLARE_API_TOKEN=...      # zone-scoped, Zone:DNS:Edit
#   terraform -chdir=terraform/dns-zone init
#   terraform -chdir=terraform/dns-zone apply -auto-approve
#
# Creates:
#   <dns_subdomain>.<dns_zone>       A -> edge_public_ip
#   *.<dns_subdomain>.<dns_zone>     A -> edge_public_ip
#
module "dns" {
  source = "../dns"

  dns_zone        = var.dns_zone
  dns_subdomain   = var.dns_subdomain
  edge_public_ip = var.edge_public_ip
}
