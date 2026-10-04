# Terraform — AWS infrastructure for the nexus K8s lab

This directory provisions the AWS infrastructure for the `nexus-dev` Kubernetes SRE lab. It is intentionally minimal: **no AWS managed load balancer** (no ALB/NLB/Gateway Load Balancer) — all L4/L7 load balancing is handled by HAProxy on `edge-01`. Phase 1 covers infrastructure. kubeadm + Cilium are wired in via `make k8s` + `make cni` + `make gateway`; GitOps (Argo CD) is pending — `gitops/` is a stub.

## Cluster identity

| Field | Value |
|---|---|
| Cluster name | `nexus` |
| Environment | `dev` |
| Region | `ap-south-1` |
| AMI | Ubuntu 24.04 LTS (Noble), dynamic lookup, owner `099720109477` |
| Edge instance type | `t3a.small` |
| Node instance type | `t3a.medium` |

## Architecture

```text
Region: ap-south-1
VPC: 10.40.0.0/16 (DNS support + hostnames)

  Public (map_public_ip_on_launch = true)
    ap-south-1a  10.40.0.0/24   edge-01  (HAProxy + bastion + NAT)
    ap-south-1b  10.40.1.0/24   reserved
    ap-south-1c  10.40.2.0/24   reserved

  Private (no public IPs, egress via edge-01 NAT)
    ap-south-1a  10.40.10.0/24  node-01
    ap-south-1b  10.40.11.0/24  node-02
    ap-south-1c  10.40.12.0/24  node-03

  Route tables
    public-RT  -> IGW
    private-RT -> edge-01 primary ENI (default route 0.0.0.0/0)
```

Traffic model:

```text
Internet
   |
edge-01:6443  (HAProxy fronts kube API)
   |
   +--> node-01:6443
   +--> node-02:6443
   +--> node-03:6443

Internet
   |
edge-01:443   (HAProxy fronts app traffic → cilium-envoy)
   |
   +--> node-01:443
   +--> node-02:443
   +--> node-03:443
```

## Module layout

```text
terraform/
├── versions.tf          required_version + provider version constraints
├── providers.tf         AWS + Cloudflare provider config
├── variables.tf         all input variables (defaults safe; see terraform.tfvars.example)
├── locals.tf            common_tags, node_names
├── main.tf              module wiring
├── outputs.tf           vpc_id, subnets, instance IDs/IPs, ansible_inventory_yaml
├── templates/
│   └── inventory.yml.tftpl
├── terraform.tfvars.example
│
├── network/             VPC, IGW, subnets, NAT GW + EIP, route tables
├── firewall/            edge-bastion + nodes SGs (least privilege)
├── vps/                 2 key pairs, dynamic AMI, 4 EC2, optional EIP
└── dns/                 Cloudflare records (count-gated by enable_dns)
```

## NAT decision

By default (`edge_enable_nat = true`), edge-01 doubles as the NAT gateway. edge-01 runs Ubuntu 24.04 with `iptables-persistent` and a `MASQUERADE` rule for the VPC CIDR, installed via `user_data`. `source_dest_check` is disabled on the edge ENI (required for routing). The private route table's `0.0.0.0/0` route targets edge-01's primary ENI — no separate NAT instance, no NAT EIP.

Setting `edge_enable_nat = false` provisions a dedicated NAT **instance** (EC2 `t4g.nano`, ~$3/mo) in `ap-south-1a` instead. Use that if you want to free up CPU/RAM on edge-01, or eventually move to two NAT instances for HA. The opt-in path keeps `nat_instance_type` for that case.

NAT instance is ~10× cheaper than a managed NAT Gateway but requires you to maintain the AMI (Ubuntu LTS is fine) and accept that an `ap-south-1a` outage breaks egress for all three nodes — single-AZ NAT, documented as a known lab limitation. No native failover.

Estimated cost drivers (ap-south-1, on-demand, USD/month, 24/7, `edge_enable_nat = true`):

| Resource | Cost |
|---|---|
| 4× t3a.small/medium (edge + 3 nodes; edge handles NAT) | ~$30 |
| Dedicated NAT instance | (skipped) |
| 4× gp3 30GB root volumes | ~$4 |
| Data transfer | variable |

## Security groups

Three SGs, least privilege:

`nexus-dev-edge-bastion`:
- 22/tcp from `ssh_admin_cidrs`
- 6443/tcp from `kubernetes_api_allowed_cidrs`
- 80/tcp, 443/tcp from `http_allowed_cidrs`
- egress: all

`nexus-dev-nodes`:
- 22/tcp from `nexus-dev-edge-bastion` SG (ProxyJump)
- 6443/tcp from `nexus-dev-edge-bastion` SG (HAProxy front)
- all from `nexus-dev-nodes` SG (self — CNI, etcd, kubelet)
- egress: all

`nexus-dev-nat` (only when `edge_enable_nat = false`):
- 22/tcp from `ssh_admin_cidrs` (management)
- egress: all

No `0.0.0.0/0` ingress on the nodes SG.

## SSH

Two ed25519 key pairs live on your laptop only. Their **public keys** are loaded into Terraform via `file()`:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/nexus_edge  -C "nexus-edge"
ssh-keygen -t ed25519 -f ~/.ssh/nexus_nodes -C "nexus-nodes"
```

`edge-01` is injected with `nexus_edge.pub`. All three nodes get `nexus_nodes.pub`. The bastion never holds the node private key.

`~/.ssh/config`:

```text
Host edge-01
    HostName <edge_public_ip>
    User ubuntu
    IdentityFile ~/.ssh/nexus_edge
    IdentitiesOnly yes

Host node-01 node-02 node-03
    User ubuntu
    IdentityFile ~/.ssh/nexus_nodes
    IdentitiesOnly yes
    ProxyJump edge-01
```

Usage:

```bash
ssh edge-01
ssh node-01
ssh node-02
ssh node-03
```

No `ForwardAgent`. Bastion never holds the node private key.

## Usage

1. Generate the SSH keys (one-time, on your laptop).
2. `cp terraform.tfvars.example terraform.tfvars` and edit `ssh_admin_cidrs` to your IP/32.
3. AWS creds — any of: env vars `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, `~/.aws/credentials`, or SSO profile. Cloudflare only if `enable_dns=true`: `export TF_VAR_cloudflare_api_token=...`
4. `terraform init`
5. `terraform plan -out=tfplan` — review the diff.
6. `terraform apply tfplan`

The Terraform `ansible_inventory_yaml` output matches `../ansible/inventory/hosts.yml` exactly. After `apply`, regenerate the file with `terraform output -raw ansible_inventory_yaml > ../ansible/inventory/hosts.yml` (the existing file has placeholder IPs).

## Variables worth knowing

| Variable | Default | Notes |
|---|---|---|
| `cluster_name` | `"nexus"` | tag/Name prefix |
| `environment` | `"dev"` | tag |
| `aws_region` | `"ap-south-1"` | |
| `ssh_admin_cidrs` | `["129.154.251.111/32"]` | **set this to your real IP** |
| `edge_instance_type` | `"t3a.small"` | |
| `node_instance_type` | `"t3a.medium"` | |
| `edge_enable_nat` | `true` | set false to spawn a dedicated NAT instance |
| `enable_elastic_ip` | `false` | set true to allocate an EIP for edge-01 |
| `enable_dns` | `false` | set true to manage Cloudflare records |
| `dns_zone` | `"example.com"` | Cloudflare zone (when enabled) |
| `dns_subdomain` | `"edge"` | → `edge.example.com` |
| `cloudflare_api_token` | `""` | pass via env, never commit |

See `terraform.tfvars.example` for the full list.

## Outputs

| Output | Purpose |
|---|---|
| `vpc_id`, `public_subnet_ids`, `private_subnet_ids` | debug |
| `edge_public_ip` | SSH target, DNS target |
| `edge_private_ip` | debug |
| `edge_instance_id` | debug |
| `nat_source` | `"edge-01"` or `"nat-instance"` |
| `nat_instance_id`, `nat_eip_public_ip` | null when edge does NAT |
| `node_private_ips` | map `node-01..03` → private IP |
| `node_instance_ids` | map `node-01..03` → instance ID |
| `ssh_command_edge` | convenience SSH command |
| `ssh_command_node_via_edge` | map of node → ProxyJump command |
| `ansible_inventory_yaml` | full Ansible inventory YAML |

## Deliberate lab simplifications

- Single NAT instance in one AZ (no HA).
- No Flow Logs.
- No KMS encryption for EBS beyond default AWS-managed keys.
- No IRSA / OIDC.
- `ubuntu` user is the bootstrap user; a dedicated `ansible` user is a later refactor.
- `kubernetes_api_allowed_cidrs` and `http_allowed_cidrs` default to `0.0.0.0/0` because HAProxy is the public LB front. Tighten in `terraform.tfvars` if your threat model requires it.
- Hostnames (`edge-01`, `node-01..03`) are set in `user_data` on first boot via `hostnamectl` + `/etc/hosts`. `user_data_replace_on_change` is left at its default (`false`), so updating the script in-place does not re-run it on already-running instances — replace the instance (`terraform apply -replace=...`) or destroy+recreate to re-apply.

## Known limitations

- Destroying the lab loses the ephemeral public IP of `edge-01`. Enable `enable_elastic_ip` and/or `enable_dns` if you need persistence across rebuilds.
- Single-AZ NAT (edge-01 lives in `ap-south-1a`): an `ap-south-1a` outage takes egress with it AND kills the bastion/HAProxy front. Mitigate by toggling `edge_enable_nat = false` and running a dedicated NAT instance in the same AZ, or by accepting the lab's blast radius.
- No remote state backend configured by default — see the top-level `README.md` for S3 + DynamoDB setup.
- Edge-01 is a single point of failure for both public ingress and private egress when `edge_enable_nat = true`. A dedicated NAT instance (`edge_enable_nat = false`) isolates the failure modes but does not provide HA.