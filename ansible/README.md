# Ansible

Ansible owns node configuration and cluster bootstrap.

## Roles

- `common` — OS baseline: packages, swap off, kernel modules, sysctl, chrony, timezone.
- `containerd` — container runtime (systemd cgroup driver).
- `kubernetes` — kubelet/kubeadm/kubectl from the Kubernetes apt repo (`pkgs.k8s.io`).
- `haproxy` — external L4 load balancer for the kube API and HTTP(S) traffic to nodes.
- `kubeadm` — `kubeadm init` on first control plane + `kubeadm join` on remaining control planes; captures upload-certs key + join command for downstream nodes.
- `cni` — Cilium install via Helm (replaces kube-proxy).
- `local_netplan` — node-side netplan config for the local-VM lab: suppresses the DHCP search domain (`use-domains: false`) so pod DNS is not hijacked, and pins a persistent default route via the edge gateway.

## Playbooks

| Playbook | Targets | Roles/tasks |
|---|---|---|
| `bootstrap.yml` | all hosts | common |
| `haproxy.yml` | edge | haproxy |
| `kubernetes.yml` | control_plane + workers | common, containerd, kubernetes |
| `cluster.yml` | node-01 (init/cni) + node-02,node-03 (join) | kubeadm, cni |
| `cluster-gateway.yml` | control_plane | Cilium Gateway API CRDs + `web` Gateway + envoy host-port check |
| `cluster-cert.yml` | node-01 | cert-manager (Helm) + ClusterIssuer + Certificate (`enable_dns=true` → DNS-01/Cloudflare, else HTTP-01) |
| `cluster-observability.yml` | node-01 | VictoriaMetrics stack via `victoria-metrics-k8s-stack` + `vm-overrides.yaml` |
| `cluster-demo.yml` | node-01 | `podinfo` Deployment/Service/HTTPRoute in `demo` namespace |
| `local-prep.yml` | kubernetes | local_netplan (no DHCP search domain, default route via edge) |
| `cleanup.yml` | control_plane (once) + all hosts | bootstrap-token cleanup, then scratch files, shell history, apt cache, journal — for snapshotting |

Driven end-to-end by the top-level `Makefile`. See `make help`.

### Alertmanager payload (observability tier)

Four things about `roles/observability/templates/alertmanager-config.yaml.j2` that
are easy to get wrong and hard to see from the outside:

- **`group_by` is set explicitly** to `['alertname', 'severity']`. Alertmanager's
  default is "all labels except alertname", which leaves `.CommonLabels.alertname`
  empty whenever a group holds more than one alertname — and
  `.CommonAnnotations.summary` empty too, because annotations are not labels. A
  `Common*`-based payload then delivers blank `alertname` / `summary` /
  `description` for every notification.
- **Every payload value goes through `toJson`.** Alertmanager requires the
  webhook payload to be valid JSON, and most of the chart's default rules carry
  descriptions with double quotes and newlines. Interpolating them raw puts an
  unescaped quote inside a JSON string and the body stops being JSON. The
  symptom is invisible: ntfy.sh re-serialises a valid body (compact, keys
  sorted) but stores an invalid one as raw text, so the same alert reaches the
  topic in two different shapes depending on whether its description happens to
  contain a quote.
- **Both receivers need a `webhook_configs` entry.** A receiver with no
  integration silently drops its alerts — the route still matches, the
  notification just never arrives.
- **The pod does not read `alertmanager-vm-external` directly.** The operator
  copies `spec.configSecret` into its own `vmalertmanager-<name>-config`
  secret, and the config-reloader sidecar renders *that* into the file the
  Alertmanager loads (`--config.file=/etc/alertmanager/config/alertmanager.yaml`).
  Check the operator's copy, not ours, when the running config and the repo
  disagree.

### `kube-prometheus-general.rules` is disabled on purpose

`roles/observability/templates/vm-overrides.yaml.j2` turns that rule group off:

```yaml
defaultRules:
  groups:
    kube-prometheus-general.rules:
      enabled: false
```

The group holds exactly two recording rules — `count:up0` and `count:up1` —
both of the form `count(up == N) without(instance,pod,node)`. When every
scrape target is healthy, `up == 0` matches nothing, the expression returns
an **empty vector**, and the recording rule writes **zero samples**. vmalert's
built-in `RecordingRulesNoData` alert then fires ("produces 0 samples over the
last 30min") *because nothing is broken*. A self-referential false positive:
the alert about missing data is caused by there being no data to report.

Verified live before disabling: `RecordingRulesNoData` / severity `info` /
alertgroup `vmalert`, firing alongside the healthy `Watchdog` and
`InfoInhibitor` from `general.rules`.

Mechanism: the chart renders its default rule groups from this values map in
`templates/sync-job/config.yaml`, and the chart's sync job creates the
matching `VMRule` objects. A group with `enabled: false` is skipped, so the
`VMRule` is never created. Chart 0.97.0 defaults this group to `false`;
the pinned 0.95.0 does not, hence the explicit override. Helm deep-merges the
group map, so the chart's own `rules: {}` default survives.

The `up` metric itself is unaffected — it comes from vmagent's scrape.

### `cluster-gateway.yml` — three things it must do itself

The Gateway tier is the first playbook to touch Cilium after the CNI role,
and it has three failure modes that all look like "the Gateway is broken":

1. **Helm repo cache.** `helm upgrade cilium cilium/cilium` reads a cached
   repo index under `/root/.cache/helm/repository/`. That cache is not
   guaranteed to exist (fresh node, cleaned host, fresh snapshot), and the
   CNI role is the only other place that refreshes it. The playbook now runs
   `helm repo add --force-update` + `helm repo update` itself, so it works
   standalone.
2. **The agent never reloads the Gateway config.** `enable-gateway-api` and
   `gateway-api-hostnetwork-enabled` live in the `cilium-config` ConfigMap and
   the cilium-agent reads them **at startup only**. `helm upgrade` rewrites
   the ConfigMap but does not change the DaemonSet pod template, so no agent
   pod is recreated and the agent keeps running with Gateway API disabled —
   `cilium-envoy` then binds no host port at all. The playbook restarts
   `ds/cilium` and `ds/cilium-envoy` after the upgrade for this reason.
   (`cilium-operator` needs the same treatment for its own flag — it is
   restarted separately.)
3. **`Programmed=True` is not proof.** The Gateway reports
   `Programmed=True` even when the agent never picked up the config. The
   playbook therefore checks the socket (`ss -ltn | grep ':80 '`) and fails
   when `cilium-envoy` is not bound on host port 80.

Port 443 stays closed until cert-manager issues the `web-tls` Secret — the
HTTPS listener reports `InvalidCertificateRef` and is not programmed without
it.


## Inventory

`inventory/hosts.yml` is generated by Terraform from the actual deployed IPs. Regenerate after every `terraform apply`:

```bash
terraform -chdir=../terraform output -raw ansible_inventory_yaml > inventory/hosts.yml
```

`inventory/local.yml` is the hand-maintained inventory for the **local-VM lab**
(no Terraform). It encodes the same var names, so `group_vars/all.yml` resolves
unchanged. Never regenerate it — the `make inventory` target writes to
`inventory/hosts.yml`, but the `local-*` Makefile targets deliberately do not
depend on it.

The ProxyCommand uses the bastion (edge-01) — make sure `~/.ssh/nexus_edge` is loaded into ssh-agent, or that your `~/.ssh/config` maps `edge-01` to that key.

Local-lab notes:

- Nodes are reachable only through the edge bastion. `all.vars` carries the
  ProxyCommand; `edge-01` overrides it back to `''` because it is directly
  reachable.
- `edge_enable_nat: false` — the edge's WireGuard + policy-routing path is
  hand-built. The AWS-flavoured `nat` role would MASQUERADE the wrong subnet
  and run `netfilter-persistent save`, baking live tunnel rules into
  `rules.v4`.
- The VMs keep their provisioned hostnames (`master`, `node1`, `node2`).
  `kubeadm --node-name` makes kubeadm pass `--hostname-override` to the
  kubelet, so the Node objects are named `node-01/02/03` while the VMs keep
  their original names.
- `kubelet_prereq` adds an `/etc/hosts` line mapping the inventory name to
  the node's LAN IP, which clears kubeadm's hostname preflight.
- `local_netplan` must run before the cluster comes up (`make local-prep`).
  The LAN DHCP server hands out the search domain `0x40.net`, and kubelet
  copies the host's search domains into every pod's `/etc/resolv.conf` with
  `options ndots:5`. A 3-dot name like `svc.ns.svc.cluster.local` then
  search-expands to `...cluster.local.0x40.net`, which the LAN DNS wildcard
  answers with the wrong IP. netplan's `dhcp4-overrides.use-domains: false`
  emits `UseDomains=false` into the generated systemd-networkd unit, which
  drops the search domain while leaving the DHCP DNS *server* in place
  (`use-dns` and `use-domains` are independent knobs). DNS servers are
  intentionally not pinned — they come from the upstream DHCP lease.

### Snapshot cleanup

`cleanup.yml` has two plays and runs in this order:

1. **Cluster play** (`control_plane`, `run_once`) — deletes leftover kubeadm
   bootstrap tokens. It has to be a separate play from the host cleanup
   because edge-01 has no `kubectl` and no `/etc/kubernetes/admin.conf`.
   kubeadm does not delete the token it consumed on join, so a cluster that
   has been up for a while still carries them until
   kube-controller-manager's `tokencleaner` GC's them at expiry. Leaving a
   valid one in a snapshot means restoring a token that can still join a
   rogue node. The task is idempotent and normally a no-op. **Do not run it
   while a node join is in flight** — the join consumes the token.
2. **Host play** (`all`) — trims every VM: operator scratch files in `/tmp`,
   shell history, editor/pager state, Ansible remote-temp residue, the apt
   package cache and the systemd journal. It deliberately leaves cluster
   state (`/var/lib/etcd`, `/var/lib/containerd`, `/etc/kubernetes`) and the
   edge's WireGuard keys alone — a snapshot is meant to restore a working
   cluster.

Opt-in extras, all off by default and all driven by vars:

| Var | Effect | Measured |
|---|---|---|
| `cleanup_purge_apt_lists` | removes `/var/lib/apt/lists` (needs `apt-get update` after restore) | 205M/node |
| `cleanup_helm_cache` | removes `/root/.cache/helm`, `/home/ubuntu/.cache/helm` | 6.4M/node |
| `cleanup_pod_logs` | removes kubelet's per-pod logs under `/var/log/pods` | 1.7M/node |
| `cleanup_prune_exited_containers` | `crictl rm` on every container in `Exited` state | 19/14/22 per node |
| `cleanup_prune_containerd_images` | installs `cri-tools` if no `crictl`, then `crictl rmi --prune` | see below |

The last two are **not** part of `make local-cleanup-snapshot`.

`cleanup_prune_containerd_images`: `crictl rmi --prune` removes every image
not referenced by a running container, which includes the images of
Deployments that are scaled to 0 and of pods that have not been created yet
— after a restore those must be re-pulled over the WireGuard tunnel. It is
also worth little here: all 17–19 CRI-visible images in this cluster are in
use by a running pod.

`cleanup_prune_exited_containers`: an exited container keeps its containerd
overlayfs snapshot until the container record is deleted. The kubelet GCs
those itself once the owning pod is gone, but the ones belonging to a
still-running pod (a restarted container) stay — and so do the pre-reboot
instances of the static pods (etcd, kube-apiserver, kube-scheduler,
kube-controller-manager). This is the main reason the per-node disk usage
drifts apart: node-03 held 22 exited containers and 188 overlayfs snapshots
against node-02's 14 and 147, which is 1.6G of the disk.

`make local-cleanup` runs the safe subset. `make local-cleanup-snapshot`
additionally purges the apt indexes, clears the pod logs and the helm cache,
and drops the bootstrap tokens.

The `/tmp` sweep runs last on purpose: Ansible writes a module payload file
into the remote temp dir for every command/shell task, so a sweep placed
before the final command task only relocates the litter. That is also why
the cluster play runs first — its `kubectl` calls leave payloads in `/tmp`
too, and the sweep has to come after them.

## Group vars

`group_vars/all.yml` holds cluster-wide constants:

- `kubernetes_cluster_name` (must match terraform `cluster_name` — currently `nexus`)
- `kubernetes_version` (pinned)
- `kubernetes_api_endpoint` (edge-01 public IP from `terraform output edge_public_ip`)
- `kubernetes_pod_subnet`, `kubernetes_service_subnet` (Cilium-compatible ranges)
- HAProxy port defaults, kernel modules, sysctl, baseline packages

## Usage

Either run the full pipeline from the top-level `Makefile` (`make all`), or invoke playbooks individually. After Terraform apply + `make inventory`:

```bash
# 1. OS baseline on all hosts
ansible-playbook playbooks/bootstrap.yml

# 2. containerd + kubelet on K8s nodes
ansible-playbook playbooks/kubernetes.yml

# 3. HAProxy on edge
ansible-playbook playbooks/haproxy.yml

# 4. kubeadm init + Cilium + joins
ansible-playbook playbooks/cluster.yml

# 5. Gateway API + web Gateway + HTTPRoute
ansible-playbook playbooks/cluster-gateway.yml

# 6. cert-manager + LE cert (HTTP-01 by default, DNS-01/Cloudflare if enable_dns=true)
ansible-playbook playbooks/cluster-cert.yml

# 7. VictoriaMetrics stack (vmsingle + vmagent + vmalert + Grafana)
ansible-playbook playbooks/cluster-observability.yml

# 8. demo app (podinfo)
ansible-playbook playbooks/cluster-demo.yml
```

After step 4, `kubectl get nodes` from node-01 should show all three control planes `Ready`, with `cilium-*` pods running in `kube-system`.

### Local-VM lab

Same playbooks, static inventory, no Terraform:

```bash
make local-prep          # netplan: no DHCP search domain, route via edge-01
make local-bootstrap      # common role on edge + nodes
make local-k8s           # containerd + kubelet/kubeadm/kubectl
make local-cluster       # kubeadm init + Cilium + control-plane joins
make local-gateway       # Gateway API CRDs + web Gateway
make local-cert          # cert-manager + LE (needs CLOUDFLARE_API_TOKEN)
make local-observability # VictoriaMetrics stack (needs GRAFANA_ADMIN_PASSWORD)
make local-demo          # podinfo demo
make local-test          # HTTP probes through edge-01
make local-cleanup       # trim scratch/history/caches before snapshotting
make local-cleanup-snapshot  # + apt indexes, pod logs, helm cache, bootstrap tokens
```

`local-all` chains all of them. These targets never touch Terraform and never
regenerate `inventory/local.yml`.

## Re-running `cluster.yml`

Note: stateful. Re-run needs `kubeadm reset` on each node first.

`cluster.yml` is idempotent only when no prior kubeadm state exists. If init or join has already succeeded on a node, you must reset before re-running:

```bash
# On each node that already ran kubeadm init or join:
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /home/ubuntu/.kube
```

Then re-run `playbooks/cluster.yml`.
