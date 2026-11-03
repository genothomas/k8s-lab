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
| `cluster-gateway.yml` | control_plane | Cilium Gateway API CRDs + `web` Gateway + envoy host-port check + firewall re-assert |
| `gateway-firewall.yml` | control_plane | `gateway_firewall` — re-applies the rule set and puts the `K8SGW` jump back in first position |
| `gateway-proxy-protocol.yml` | control_plane + edge | PROXY v2 cutover: firewall → Cilium → edge reload |
| `gateway-forge-probe.yml` | node-01 | diagnostic — in-cluster PROXY-header forgery probe |
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

### Envoy access logs (`CiliumGatewayClassConfig`)

Per-request access logs for every Gateway on the `cilium` GatewayClass —
no extra proxy, no CNI upgrade. Cilium 1.20.2 already ships the
`CiliumGatewayClassConfig` CRD (`cilium.io/v2alpha1`), and the installed
Gateway API CRDs (v1.6.2) support `GatewayClass.spec.parametersRef`.

`apps/web/70-gateway-access-logs.yaml.j2` holds the config:

```yaml
spec:
  telemetry:
    accessLogs:
      - format: JSON
        targets: [HTTP]
        json:
          start_time: '%START_TIME%'
          gateway: '%CILIUM_GATEWAY_NAME%'
          method: '%REQUEST_HEADER(:METHOD)%'
          host: '%REQUEST_HEADER(:AUTHORITY)%'
          path: '%REQUEST_HEADER(X-ENVOY-ORIGINAL-PATH?:PATH)%'
          status: '%RESPONSE_CODE%'
          duration_ms: '%DURATION%'
          ...
```

Read them with:

```bash
kubectl -n kube-system logs -l k8s-app=cilium-envoy --all-containers -f --prefix
```

**Use the label selector, not `ds/cilium-envoy`.** `kubectl logs ds/...` prints
`Found 3 pods, using pod/cilium-envoy-vnsdl` and silently shows only ONE pod's
logs. The edge HAProxy round-robins across node-01/02/03, so a request can
land on any of the three — you will "lose" most requests.

Verified live (2026-11-02) — a request to the gateway produced:

```json
{"bytes_received":0,"bytes_sent":0,"duration_ms":7,"gateway":"web","gateway_namespace":"web",
 "host":"demo.svc.dotunet.com","method":"GET","path":"/","protocol":"HTTP/1.1",
 "remote_address":"10.42.0.74:50608","response_flags":"-","sni":null,
 "start_time":"2026-11-02T07:47:33.287Z","status":301,"upstream_cluster":null,
 "upstream_host":null,"upstream_time_ms":null,"user_agent":"curl/8.11.1",
 "x_forwarded_for":"10.42.0.74"}
```

`upstream_host` / `upstream_cluster` / `upstream_time_ms` are `null` for a
redirect: the request never reached a backend, so Envoy has no upstream to
report. A routed request to podinfo fills them in.

### Testing the access logs from the client side

The public path is: DNS `*.svc.dotunet.com` → VPS `152.67.31.10` → DNAT :443
→ edge-01 HAProxy → node `:443` → cilium-envoy → Gateway listener → HTTPRoute.

```bash
# 1. HTTP → HTTPS redirect (the `redirect` HTTPRoute is on the `http` listener)
curl -v -I http://demo.svc.dotunet.com/     # expect 301 → https://demo.svc.dotunet.com:443/

# 2. Real app over TLS (cert SAN is *.svc.dotunet.com, so verification passes)
curl -v https://demo.svc.dotunet.com/        # expect 200 podinfo
curl -v https://grafana.svc.dotunet.com/     # grafana

# 3. Negative cases
curl -v -I http://typo.example.com/          # 404, no matching host
curl -v -k https://152-67-31-10.nip.io/      # cert mismatch → -k (host route exists)

# 4. Watch the logs while you curl
kubectl -n kube-system logs -l k8s-app=cilium-envoy --all-containers -f --prefix
```

Two things that bite here:

- **The client IP is flattened at the edge — in exactly one hop.** Measured on
  the running lab (2026-11-02):
  - On edge-01, the established socket on `:443` shows the **real public
    client** as peer (e.g. `103.189.143.226:6266`). The VPS DNATs `:443` to
    the edge and **preserves the source IP** — no proxying happens there.
    Note: in this lab `103.189.143.226` is the lab's *own* public egress
    address (confirmed with `https://api.ipify.org` run from edge-01), so the
    traffic being measured comes from the lab itself, not a third party.
  - Envoy on the nodes logs `"remote_address":"192.168.16.30:<port>"` for every
    internet request, and `x_forwarded_for` is the same single value.
  - Cause: edge HAProxy runs `mode tcp` (pure TCP tunnel — it opens a *new*
    connection to the node with the edge's own source IP and adds no
    `X-Forwarded-For` header). The original client address is therefore gone
    before Cilium ever sees it.
  - XFF trust semantics, verified by spoofing `X-Forwarded-For: 9.9.9.9` from
    a pod: Envoy logged `"9.9.9.9,10.42.0.34"` — it **appends** the TCP peer
    and keeps the right-most entry authoritative. With `useRemoteAddress:
    true` + `xffNumTrustedHops: 0` the client IP is *not* spoofable.
  - Fixing it means fixing the edge, not Cilium: **PROXY protocol v2 end to
    end** — HAProxy `server ... send-proxy-v2` on the node backends plus
    `gatewayAPI.enableProxyProtocol: true`. See "Client IP: PROXY protocol v2"
    below.
- **Public traffic lands on the `https` listener, so it 404s on the apex
  host.** The VPS DNATs only :443, and the `redirect` HTTPRoute is attached to
  `sectionName: http`. A request for `https://svc.dotunet.com/` therefore
  reaches the `https` listener, where no route matches that host → 404 with
  `response_flags: NR`. Only `demo.` / `pod.` / `grafana.` sub-hosts are routed
  on `https`. The redirect only fires for traffic that actually reaches :80.

### Client IP: PROXY protocol v2

`gateway_proxy_protocol: true` (in `ansible/group_vars/all.yml`) turns on the
PROXY protocol between the edge HAProxy and the Cilium Gateway listeners, so
the access log shows the real client instead of `192.168.16.30`.

```
client ──▶ VPS 152.67.31.10 (DNAT, source preserved)
        ──▶ edge-01 :443 (HAProxy, peer = real client)
        ──▶ PROXY v2 header ──▶ node :443 ──▶ cilium-envoy
```

**How each side is configured**

| Side | Setting | Where |
|------|---------|-------|
| Edge HAProxy | `server … check send-proxy-v2 check-send-proxy` | `roles/haproxy/templates/haproxy.cfg.j2` |
| Cilium | `gatewayAPI.enableProxyProtocol: true` | `roles/cni/templates/cilium-overrides.yaml.j2` |
| Nodes | only `192.168.16.30` may reach `:80`/`:443` | `roles/gateway_firewall/` |

`check-send-proxy` is **required**, not cosmetic: `send-proxy-v2` only affects
forwarded traffic — health-check connections are separate, and HAProxy only
puts the PROXY header on them when `check-send-proxy` is set. Without it the
check connection arrives without a header and Envoy closes it.

**Verified on the running lab (2026-11-02)**

- Envoy access log after the cutover, for **real third-party traffic** that
  happened to reach the public listener:

  ```
  "remote_address":"45.148.10.120:60024",
  "x_forwarded_for":"45.148.10.120",
  "x_envoy_external_address":"45.148.10.120"
  ```

  Before the cutover every one of those lines read
  `"remote_address":"192.168.16.30:<port>"`.
- A spoof attempt (`X-Forwarded-For: 9.9.9.9`) is logged as
  `xff= 9.9.9.9,103.189.143.226` — the forged value stays **left** of the
  authoritative entry, so it does not win.
- `x_envoy_external_address` is now populated (it was `null` before, because
  a request with no XFF from a RFC1918 downstream counts as *internal*).
- A connection to `node-01:443` **without** a PROXY header hangs until the
  client times out — Envoy is waiting for the header, i.e. PROXY is genuinely
  required, not optional.
- `K8SGW` counters on node-01: `ACCEPT` 3213 pkts (`:80`) / 3264 pkts (`:443`)
  from the edge, `DROP` 5 pkts on `:443` from everything else.
- All six HAProxy backends (`k8s-http` / `k8s-https` × node-01/02/03) report
  `status= UP`.

**What PROXY protocol costs**

- Cilium's `gatewayAPI.enableProxyProtocol` is **operator-global**, not
  per-Gateway. It installs Envoy's `proxy_protocol` listener filter with
  `allow_requests_without_proxy_protocol` unset (i.e. false), so **only
  connections carrying a PROXY header are accepted**. Consequences:
  - ClusterIP, NodePort and direct-node access to the Gateway **stop serving**
    (a client without a PROXY header is closed before the request is parsed);
    the edge is the only path that works;
  - it applies to every Gateway listener in the cluster, not just the web one;
  - the PROXY header is **not authenticated** — anything that can reach a
    node's `:80`/`:443` can forge a client IP. Hence the `gateway_firewall`
    role, which drops everything except the edge. The edge itself remains
    trusted by construction: PROXY protocol v2 has no authentication, so a
    compromised edge can still claim any client address. Closing that would
    need a mechanism Cilium's listener filter does not offer.
- The Kubernetes API port (6443) is untouched — the API backends keep plain
  TCP.

**Why the `K8SGW` jump must be the FIRST rule in `INPUT`**

`CILIUM_INPUT` contains exactly one rule:

```
-A CILIUM_INPUT -m mark --mark 0x200/0xf00 -m comment --comment "cilium: ACCEPT for proxy traffic" -j ACCEPT
```

That accepts Cilium-proxied traffic (mark `0x200`, set by `CILIUM_PRE_mangle`
for anything redirected to the host proxy). If `K8SGW` sits behind it, that
traffic is ACCEPTed before the `K8SGW` DROP rules are ever evaluated.

Cilium inserts its own jump at position 1 of `INPUT` and **the ordering
decays on its own** — measured on the running lab: the `K8SGW` jump was
verified in first position, and was back at position 2 later with the
cilium agents showing **0 restarts** (4h uptime). So this is not only an
agent-restart problem.

The role re-asserts the jump position on every run (`Ensure the K8SGW jump
is the first rule in INPUT`): it deletes the misplaced jump and re-inserts
it at position 1. Do not "simplify" that task away — `iptables -I INPUT 1`
alone is not enough, because the ordering decays again without a restart.

Re-assert it on demand:

```bash
make local-gateway-firewall   # re-apply the rule set and the jump position
```

**In-cluster forgery — what the measurements show**

The PROXY header is not authenticated, so *anything* that can open a
connection to a Gateway listener can claim an arbitrary client address. The
question is which actors can actually get there. Measured on the running
lab (2026-11-02/03) with `make local-gateway-probe`, which sends requests
from a throwaway pod and from the node's own host network namespace, and
decides the verdict from the Envoy access log:

| Path | `K8SGW` first (ordered) | `CILIUM_INPUT` first (drifted) |
|------|------------------------|-------------------------------|
| pod → Gateway ClusterIP, plain HTTP | connection refused, `DROP :80` +5 | TCP connects (`rc=0`), no response |
| pod → Gateway ClusterIP, forged PROXY v1 | connection refused, `DROP :80` +5 | TCP connects (`rc=0`), no response |
| pod → node address `:80`, forged PROXY v1 | connection refused, `DROP :80` +5 | connection refused, `DROP :80` +5 |
| any pod → Envoy access log | no entry | **no entry** |
| node loopback → `127.0.0.1:80`, forged PROXY v1 | **forged** (see below) | **forged** (see below) |

Conclusions:

- Pod traffic **does** traverse the node's `INPUT` chain — an earlier claim in
  this file that it "never traverses INPUT, so the node firewall cannot see
  it" was wrong. It is dropped by `K8SGW` whenever the jump is in front.
- In the drifted state a pod can still open a TCP connection to the Gateway
  ClusterIP, but **the pod's bytes never reach Envoy's PROXY filter**: no
  access-log line is written, neither for a plain request nor for a forged
  PROXY header. The connection is accepted by something that is not Envoy's
  listener. So the pod cannot poison the log in either ordering.
- **The loopback path was a real forge hole, and it was open.** The `K8SGW`
  chain carried `-s 127.0.0.1 ACCEPT`, so any local process on a control
  plane — **no root required** — could reach Envoy's PROXY filter and write
  an arbitrary client IP into the access log. Measured on 2026-11-02 from
  `node-02`:
  ```
  printf 'PROXY TCP4 203.0.113.99 127.0.0.1 40000 80\r\nGET / HTTP/1.1\r\nHost: demo.svc.dotunet.com\r\n\r\n' | nc 127.0.0.1 80
  → HTTP/1.1 301 Moved Permanently
  → Envoy log: "remote_address":"203.0.113.99:40000","x_forwarded_for":"203.0.113.99"
  ```
  That is an escalation, not a non-escalation: the point of the access log
  is to attribute a request to a client, and any user with a shell on a node
  could attribute it to anyone.
  The rule was introduced in commit `64cc67a` with no recorded justification,
  and it was unused: over the whole life of the chain the loopback counters
  sat at **0 packets on node-03** (while 31490 packets of edge traffic
  passed) and **1 packet on node-01** (a probe of our own).
  The rule is now off by default (`gateway_firewall_allow_loopback: false`),
  the role actively **removes** it where it already exists, and it asserts
  afterwards that no loopback ACCEPT survived.

So: **no in-cluster forgery hole remains**, and the controls that close it
are the `K8SGW` jump position plus the absence of any loopback exception.

**The `CiliumNetworkPolicy` that was tried and removed**

A per-namespace egress deny ("allow every destination except the Gateway",
excluding both the ClusterIP `10.43.109.166` and the magic backend address
`192.192.192.192`) was implemented and applied — five namespaces, all
`VALID=True` — and **it did not deny anything**: the probe pod still
connected (`rc=0`). Cilium evaluates the egress rule *after* service
translation, where the destination is the Gateway's **node address**
(`192.168.16.25`), not the ClusterIP and not `192.192.192.192`, so neither
exclusion matched. Excluding the node addresses instead would also exclude
the Kubernetes API server on `192.168.16.25:6443` — that breaks
cert-manager and every controller in the affected namespaces.

It was therefore removed rather than shipped: a policy that claims to deny
something it does not deny is worse than no policy.

**Controls**

1. `gateway_firewall` role — node firewall, for everything that goes
   through `INPUT`. The `K8SGW` jump must stay the **first** rule in
   `INPUT` (see above); `make local-gateway-firewall` re-asserts it.
   The chain accepts **only** the edge address — including from the node
   itself, since loopback is a forge path (see above). If a measured need
   for loopback ever appears, `gateway_firewall_allow_loopback: true` turns
   it back on; the role then asserts that no loopback ACCEPT is left over
   when the flag is off, so the exception cannot survive silently on a node
   that was configured earlier.
2. Envoy's PROXY listener filter — a connection without a PROXY header is
   closed before any request is parsed, so a plain client cannot be logged
   at all.

```bash
make local-gateway-firewall   # re-assert the firewall + jump position
make local-gateway-probe      # probe whether a pod can still forge a header
```

The probe creates a throwaway pod that sends a plain request and two forged
PROXY headers, and separately attempts a forged PROXY header over loopback
from the node itself, then reports `FORGE SUCCEEDED` / `FORGE REWRITTEN` /
`FORGE BLOCKED` from the Envoy access log. It also asserts that the Gateway
is still serving (all six HAProxy backends `UP`). It is a diagnostic, not an
access mechanism — the pod is deleted at the end.

**Cutover**

```bash
make local-gateway-proxy     # firewall → Cilium → edge HAProxy reload
```

The two sides are incompatible during the transition (PROXY-required vs.
plain TCP), so there is a short outage. Cilium goes first because the helm
upgrade + operator rollout is the slow step; the edge reload happens last, so
the outage is only the gap between the operator becoming ready and the reload.

**Rollback**

```bash
# set gateway_proxy_protocol: false in ansible/group_vars/all.yml
make local-gateway-proxy
```

That drops `send-proxy-v2` on the edge and the listener filter in Cilium
together. The node firewall rules are gated on the same variable and stay
installed until the chain is removed explicitly
(`iptables -D INPUT -j K8SGW && iptables -F K8SGW && iptables -X K8SGW`).

**Diagnostics after the cutover**

Backend state without HTTP — the edge HAProxy exposes an admin unix socket
(`/var/run/haproxy-admin.sock`), so `show stat` works from a playbook or by
hand without opening a network port:

```bash
# from edge-01
python3 - <<'PY'
import socket
s = socket.socket(socket.AF_UNIX)
s.connect('/var/run/haproxy-admin.sock')
s.sendall(b'show stat\n')
for line in s.recv(200000).decode().splitlines():
    if ('k8s-http' in line or 'k8s-https' in line) and not line.startswith('#'):
        f = line.split(',')
        print(f[0], f[1], f[17])   # proxy, server, status
PY
```

In-cluster access is closed, so probe from the edge:

```bash
# from edge-01 — direct to a node, hand-crafted PROXY v1 header
printf 'PROXY TCP4 203.0.113.9 192.168.16.25 40000 80\r\nGET / HTTP/1.1\r\nHost: demo.svc.dotunet.com\r\n\r\n' \
  | nc 192.168.16.25 80

# from edge-01 — through the public path, exactly what a real client does
curl -v https://demo.svc.dotunet.com/
```

A direct connection from another node must fail:

```bash
# from node-02 — no PROXY header, and the firewall drops it anyway
nc -zv 192.168.16.25 443     # expect: refused / timeout
```

Watch the firewall counters to confirm what is being dropped:

```bash
# from any node
iptables -t filter -L K8SGW -n -v
```

To generate in-cluster traffic without a workstation curl, run a throwaway
one-shot pod (image `curlimages/curl:8.11.1` from Docker Hub) against the
gateway Service with an explicit `Host` header — **only while PROXY protocol is
off**:

```bash
kubectl -n default run accesslog-probe --image=curlimages/curl:8.11.1 \
  --restart=Never --labels=probe=accesslog -- \
  curl -sS -o /dev/null -w "HTTP=%{http_code} REDIR=%{redirect_url}\n" \
  -H "Host: demo.svc.dotunet.com" \
  http://cilium-gateway-web.web.svc.cluster.local/
kubectl -n default logs accesslog-probe
kubectl -n default delete pod accesslog-probe --ignore-not-found
```

Note: the gateway Service (`cilium-gateway-web`) has **no selector** — Cilium
manages its endpoints itself — so the apiserver's service proxy
(`/api/v1/namespaces/web/services/cilium-gateway-web:80/proxy/`) returns
`NotFound`. Use the probe pod (or an external client) to reach it.

Things that are easy to get wrong:

- **`spec.telemetry.accessLogs` is a list**, not a map — `format` is required
  (`JSON` or `Text`), and `json` maps field name → Envoy command operator.
  Supplying `json` **replaces** the CRD's default field set, so the fields
  are spelled out in full. That also means an invalid operator invalidates the
  whole config (`status.conditions` → `Accepted=False`) and access logging
  stops entirely until it is fixed.
- **The GatewayClass is Helm-owned.** `cilium` carries
  `meta.helm.sh/release-name: cilium`, and chart 1.20.2 has no value for
  `parametersRef` (its `gatewayAPI` block only has `enabled`,
  `enableProxyProtocol`, `useRemoteAddress`, `enableAppProtocol`,
  `enableAlpn`, `xffNumTrustedHops`, `externalTrafficPolicy`,
  `gatewayClass.create`, `secretsNamespace`, `hostNetwork`). Every
  `helm upgrade cilium` therefore **wipes** `spec.parametersRef`. The
  playbook patches it back *after* its own upgrade — which is why the patch
  lives in `cluster-gateway.yml` and not in a values file.
- **Logs go to Envoy stdout**, i.e. the `cilium-envoy` DaemonSet pods (this
  cluster runs `external-envoy-proxy: "true"`, the dedicated Envoy
  DaemonSet; the embedded-proxy variant would log to `ds/cilium` instead).
  Pod logs are ephemeral — ship them to Loki/Vector if they must survive a
  restart.
- **`cilium-config`'s `envoy-access-log-enabled` is a different knob.** It
  governs the *embedded* L7 proxy's own access log, not the Envoy Gateway.
  With `external-envoy-proxy: "true"` the Gateway logs come from the
  `cilium-envoy` DaemonSet and from the `CiliumGatewayClassConfig` alone.

### What the live cluster actually receives

Measured over the access logs on 2026-11-02 (all three envoy pods, ~37 lines
in a few minutes of the lab being publicly reachable):

```
status: {404: 36, 301: 1}
hosts:  {'svc.dotunet.com': 35, '152.67.31.10:80': 1, 'demo.svc.dotunet.com': 1}
```

The 35 requests to `svc.dotunet.com` are internet scanners
(`/firebase-adminsdk.json`, `/firebase-key.json`, …) hitting the public apex
name. They arrive on the `https` listener and get **404** (`response_flags: NR`
= no route), because the `redirect` HTTPRoute is bound to `sectionName: http`
and the VPS DNATs only :443. So the redirect rule is effectively dead for
public traffic — it only fires for requests that reach node `:80` directly.
If the redirect is meant to protect the public apex, either attach it to the
`https` listener too or DNAT :80 as well.


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
