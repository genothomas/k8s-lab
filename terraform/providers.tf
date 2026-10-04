provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Cloudflare provider reads CLOUDFLARE_API_TOKEN directly from the
# environment. No api_token argument here — same pattern as the AWS
# provider picking up ~/.aws/credentials.
provider "cloudflare" {}