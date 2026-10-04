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

**Ansible**

| File | What |
|---|---|
| `ansible/inventory/hosts.yml` | Generated from terraform output. Regenerate after every `terraform apply`. |
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

## Status

- [x] **Terraform** — `terraform/`. Region `ap-south-1`, cluster `nexus`/env `dev`, dual SSH keys, single NAT, no managed LB.
- [x] **Ansible + kubeadm** — `playbooks/{bootstrap,kubernetes,haproxy,cluster}.yml`. 3-node CP+worker.
- [x] **Cilium CNI + Gateway API** — `playbooks/cluster{,-gateway}.yml`. HAProxy → cilium-envoy on host 80/443.
- [x] **cert-manager + LE** — `playbooks/cluster-cert.yml`. HTTP-01 default; DNS-01/Cloudflare when `enable_dns=true`.
- [x] **VictoriaMetrics** — `playbooks/cluster-observability.yml`. vmsingle + vmagent + vmalert + AM + Grafana.
- [x] **Demo app** — `playbooks/cluster-demo.yml`. podinfo with podAntiAffinity spread.
- [ ] **GitOps** — `gitops/` stub. Flux CD not installed.
