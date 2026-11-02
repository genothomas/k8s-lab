# Kubernetes SRE Lab

A disposable VPS-based Kubernetes lab for practising Terraform, Ansible, kubeadm, Cilium + Gateway API, observability, HA, upgrades, and disaster recovery.

## Architecture

```text
                         Internet
                            |
                     +------+------+
                     |   VPS 1     |
                     | Edge/Bastion|
                     | HAProxy     |
                     | SSH/Bastion |
                     | Admin tools |
                     +------+------+
                            |
                     Private network
                            |
            +---------------+---------------+
            |               |               |
         VPS 2           VPS 3           VPS 4
         CP+Worker       CP+Worker       CP+Worker
            |               |               |
            +---------------+---------------+
                            |
                          Cilium
                            |
                  Cilium (Gateway API)
                            |
                        Services
                            |
                           Pods
```

## Stack

- Terraform: VPSs, private network, firewalling, DNS.
- Ansible: OS prep, containerd, kubelet/kubeadm/kubectl, HAProxy, cluster bootstrap.
- Cilium: CNI + Gateway API (L7 via cilium-envoy on host 80/443).
- VictoriaMetrics: vmsingle + vmagent + vmalert + Grafana.

## File map

Where to look first when something changes.

**Terraform**

| File | What |
|---|---|
| `terraform/terraform.tfvars` | Region, AZs, CIDRs, SSH keys, `enable_dns`, `dns_zone`, `dns_subdomain`. Copy from `terraform.tfvars.example`. |
| `terraform/variables.tf` | All input vars with defaults + descriptions. |
| `terraform/main.tf` | Module wiring — network → firewall → vps → dns. |
| `terraform/outputs.tf` | Includes `ansible_inventory_yaml` (consumed by `make inventory`). |
| `terraform/dns-zone/` | Standalone root module — creates only the `<sub>.<zone>` + `*.<sub>.<zone>` Cloudflare A records, without the AWS side. |

**Ansible**

| File | What |
|---|---|
| `ansible/inventory/hosts.yml` | Generated from terraform output. Regenerate after every `terraform apply`. |
| `ansible/inventory/local.yml` | Static inventory for the local-VM lab (edge-01 + 3 control planes on `192.168.16.0/26`). Hand-maintained, no Terraform. Nodes are reachable only through the edge bastion (ProxyCommand). |
| `ansible/group_vars/all.yml` | Cluster name, k8s version, CIDRs, HAProxy ports, sysctl/packages. |
| `ansible/roles/cert_manager/defaults/main.yml` | cert-manager version, Let's Encrypt email. |
| `ansible/roles/observability/defaults/main.yml` | `monitoring_namespace`, retention, `grafana_admin_*`, `alertmanager_webhook_url`. |
| `ansible/roles/observability/templates/vm-overrides.yaml.j2` | VM stack helm overrides. |
| `ansible/roles/observability/templates/custom-rules.yaml.j2` | Custom `VMRule` (node CPU high, cert expiry). |
| `ansible/roles/observability/templates/alertmanager-config.yaml.j2` | AM webhook payload to ntfy. |
| `ansible/playbooks/*.yml` | One entry point per `make` target. |

**Make + scripts**

| File | What |
|---|---|
| `Makefile` | Pipeline: terraform → inventory → bootstrap → k8s → cni → gateway → cert → observability → demo → haproxy → clean/destroy/nuke. |
| `scripts/nuke-orphans.sh` | AWS sweep for `nexus-*` resources when destroy leaves them behind. |

**Environment variables**

| Var | When | Notes |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | always | Or SSO/profile. |
| `TF_VAR_cloudflare_api_token` | `enable_dns=true` | Passed to TF / Cloudflare provider. |
| `CLOUDFLARE_API_TOKEN` | `make cert` when `enable_dns=true` | Make guard refuses to run cert phase if missing. |
| `GRAFANA_ADMIN_PASSWORD` | `make observability` / `make local-observability` | Grafana admin password (12+ chars). Read by the playbook from the environment; never stored in the repo. The Make guard refuses to run the tier if it is missing. |

## Status

- [x] **Terraform** — `terraform/`. Region `ap-south-1`, cluster `nexus`/env `dev`, dual SSH keys, single NAT, no managed LB.
- [x] **Ansible + kubeadm** — `playbooks/{bootstrap,kubernetes,haproxy,cluster}.yml`. 3-node CP+worker.
- [x] **Cilium CNI + Gateway API** — `playbooks/cluster{,-gateway}.yml`. HAProxy → cilium-envoy on host 80/443.
- [x] **cert-manager + LE** — `playbooks/cluster-cert.yml`. HTTP-01 default; DNS-01/Cloudflare when `enable_dns=true`.
- [x] **VictoriaMetrics** — `playbooks/cluster-observability.yml`. vmsingle + vmagent + vmalert + AM + Grafana.
- [x] **Demo app** — `playbooks/cluster-demo.yml`. podinfo with podAntiAffinity spread.
- [ ] **GitOps** — `gitops/` stub. Flux CD not installed.

## Local-VM lab

The same playbooks run against four local VMs on a flat `192.168.16.0/26` LAN
instead of AWS:

| Host | IP | Role |
|---|---|---|
| `edge-01` | `192.168.16.30` | NAT gateway (WireGuard uplink) + HAProxy + SSH bastion |
| `node-01` | `192.168.16.25` | control plane (kubeadm init target) |
| `node-02` | `192.168.16.26` | control plane |
| `node-03` | `192.168.16.27` | control plane |

Egress leaves the edge over a WireGuard tunnel to a remote VPS
(`152.67.31.10`, tunnel `10.8.0.1/24`, edge `10.8.0.2/24`, UDP **13231**).

The nodes are reachable from the workstation **only through the edge bastion**
(`ssh -J`), which the inventory encodes as an Ansible `ProxyCommand`.

```bash
make local-prep                # netplan: no DHCP search domain, route via edge-01
make local-k8s local-cluster   # containerd + kubelet, then kubeadm init + Cilium + joins
make local-gateway             # Gateway API CRDs + web Gateway
make local-test                # HTTP probes through edge-01
make local-cleanup             # trim scratch/history/caches before snapshotting
```

`make local-gateway` ends with a real check, not a status field: the Gateway
reports `Programmed=True` even when the cilium-agent never reloaded
`enable-gateway-api`, so the playbook fails unless `cilium-envoy` is actually
listening on host port 80. Port 443 needs cert-manager (`make local-cert`),
which is a separate step.

### DNS in the local lab

The lab's public hostname is `<dns_subdomain>.<dns_zone>` (currently
`svc.dotunet.com`), with a wildcard for `grafana.`, `pod.` and `demo.`
sub-hostnames. The A records point at the remote VPS (`152.67.31.10`), which
DNATs `:443` to edge-01's WireGuard address.

`terraform/dns-zone/` is a standalone root module that creates just those two
records (the `dns` module in `terraform/dns/` is normally wired into the AWS
root, which needs credentials this lab does not have):

```bash
export CLOUDFLARE_API_TOKEN=...        # zone-scoped, Zone:DNS:Edit
terraform -chdir=terraform/dns-zone init
terraform -chdir=terraform/dns-zone apply -auto-approve
```

`local-*` targets never depend on the `inventory` target — that one pipes
Terraform output into the inventory file and would overwrite `local.yml`.

After creating the A records, the exact name `<dns_subdomain>.<dns_zone>`
keeps returning NXDOMAIN for up to 30 minutes (the zone's SOA minimum, 1800s)
at any resolver that queried it before the record existed — RFC 2308 negative
caching. The wildcard covers sub-hostnames immediately; the apex name appears
once the negative entry expires. `terraform apply -replace` does not flush it.

Two deviations from the AWS path, both driven by the smaller boxes:

- `kubeadm_ignore_preflight_errors: "NumCPU"` — the lab nodes have 1 vCPU;
  kubeadm otherwise refuses to initialise.
- The VMs keep their provisioned hostnames (`master`, `node1`, `node2`).
  kubeadm's `--node-name` makes kubeadm pass `--hostname-override` to the
  kubelet, so the Node objects are named `node-01/02/03` to match the
  inventory keys and the playbooks, while the VMs keep their original names
  and edge's hostname-based HAProxy backends keep resolving.

### Pod DNS and the DHCP search domain

The LAN DHCP server hands out the search domain `0x40.net`. kubelet copies
the host's search domains into every pod's `/etc/resolv.conf` and hardcodes
`options ndots:5`, so a 3-dot in-cluster name like
`svc.ns.svc.cluster.local` is search-expanded first — to
`...cluster.local.0x40.net`, which the LAN DNS wildcard answers with the
wrong IP. Absolute lookups and 2-dot names worked; only the short forms
broke.

`make local-prep` (role `local_netplan`) fixes this at the netplan layer:
`dhcp4-overrides.use-domains: false` emits `UseDomains=false` into the
generated systemd-networkd unit, dropping the search domain while leaving
the DHCP DNS *server* in place. DNS servers are not pinned — they come from
the upstream DHCP lease. `use-dns` and `use-domains` are independent knobs;
`use-dns: false` only suppresses the server.
