# k8s-lab orchestration.
# Run `make help` for the full list.

ANS_INV := ansible/inventory/hosts.yml
ANS     := ansible-playbook -i $(ANS_INV)
PING    := ansible -i $(ANS_INV) all -m ping
TF      := terraform -chdir=terraform

# Local-VM lab: hand-maintained inventory, no Terraform, no AWS.
# These targets never depend on `inventory` — that target pipes terraform
# output into $(ANS_INV) and would overwrite local.yml.
LOCAL_INV  := ansible/inventory/local.yml
LOCAL_ANS  := ansible-playbook -i $(LOCAL_INV)
LOCAL_PING := ansible -i $(LOCAL_INV) all -m ping

# Wait time for hosts after terraform apply / reboot. Override cmdline.
WAIT_TIMEOUT  ?= 360
WAIT_INTERVAL ?= 10

.PHONY: all help check ping terraform inventory bootstrap k8s cni gateway cert observability demo haproxy clean destroy nuke wait-ready test \
        local-check local-prep local-bootstrap local-haproxy local-k8s local-cluster local-gateway local-cert local-observability local-demo local-test local-cleanup local-cleanup-snapshot local-all

.DEFAULT_GOAL := check

# Guards against EC2 boot + sshd warm-up (~30-90s after terraform apply).
check:
	@if [ ! -f $(ANS_INV) ]; then \
		echo "ERROR: $(ANS_INV) missing. Run 'make inventory' first."; \
		exit 1; \
	fi
	@start=$$(date +%s); \
	while :; do \
		if $(PING) >/dev/null 2>&1; then \
			elapsed=$$(($$(date +%s) - start)); \
			echo ""; \
			echo "All hosts reachable after $${elapsed}s."; \
			$(PING); \
			exit 0; \
		fi; \
		now=$$(date +%s); \
		if [ $$((now - start)) -ge $(WAIT_TIMEOUT) ]; then \
			echo ""; \
			echo "FAIL: hosts not reachable after $(WAIT_TIMEOUT)s."; \
			$(PING); \
			exit 1; \
		fi; \
		printf "."; \
		sleep $(WAIT_INTERVAL); \
	done

terraform:
	$(TF) init -upgrade
	$(TF) apply -auto-approve

inventory:
	@mkdir -p ansible/inventory
	$(TF) output -raw ansible_inventory_yaml > $(ANS_INV)

# bootstrap depends on inventory so standalone runs refresh IPs
# after a manual terraform apply.
bootstrap: inventory check
	$(ANS) ansible/playbooks/bootstrap.yml

k8s: check
	$(ANS) ansible/playbooks/kubernetes.yml

cni: check
	$(ANS) ansible/playbooks/cluster.yml

gateway: check
	$(ANS) ansible/playbooks/cluster-gateway.yml

# DNS-01 if enable_dns=true (see $(ANS_INV)).
cert: check
	@if grep -q '^    enable_dns: true' $(ANS_INV) 2>/dev/null && [ -z "$$CLOUDFLARE_API_TOKEN" ]; then \
		echo "ERROR: enable_dns=true but CLOUDFLARE_API_TOKEN unset."; \
		echo "Export it or flip enable_dns=false in $(ANS_INV)."; \
		exit 1; \
	fi
	$(ANS) ansible/playbooks/cluster-cert.yml

observability: check
	@if [ -z "$$GRAFANA_ADMIN_PASSWORD" ]; then \
		echo "ERROR: GRAFANA_ADMIN_PASSWORD unset."; \
		echo "Export it (12+ chars) — Grafana is served on the public https listener."; \
		exit 1; \
	fi
	$(ANS) ansible/playbooks/cluster-observability.yml

demo: check
	$(ANS) ansible/playbooks/cluster-demo.yml

# HAProxy on edge-01 (L4 → cilium-envoy on node ports).
haproxy: check
	$(ANS) ansible/playbooks/haproxy.yml

wait-ready: check

all: terraform inventory bootstrap haproxy k8s cni gateway cert observability demo
	@$(MAKE) test

# Probe public endpoints through HAProxy on edge-01. GET + follow redirects,
# body to /dev/null. Some apps (podinfo) reject HEAD with 405.
test:
	@if [ ! -f $(ANS_INV) ]; then echo "ERROR: $(ANS_INV) missing. Run 'make inventory' first."; exit 1; fi
	@edge_ip=$$(grep '^    edge_public_ip:' $(ANS_INV) | awk -F'"' '{print $$2}'); \
	if grep -q '^    enable_dns: true' $(ANS_INV) 2>/dev/null; then \
		apex="$$(grep '^    dns_subdomain:' $(ANS_INV) | awk -F'"' '{print $$2}').$$(grep '^    dns_zone:' $(ANS_INV) | awk -F'"' '{print $$2}')"; \
	else \
		apex="$$(grep '^    nip_apex:' $(ANS_INV) | awk -F'"' '{print $$2}')"; \
	fi; \
	echo "edge-01 (HAProxy + SSH bastion): $${edge_ip}"; \
	echo ""; \
	for h in grafana pod demo; do \
		curl -sL --connect-timeout 5 --max-time 15 --retry 2 --retry-connrefused -o /dev/null \
			-w "%{http_code} $${h}.$${apex}\n" \
			"https://$${h}.$${apex}" \
			--resolve "$${h}.$${apex}:443:$${edge_ip}"; \
	done

# ---------------------------------------------------------------------------
# Local-VM lab (192.168.16.0/26 LAN: edge-01 + 3 control planes).
# Static inventory, no Terraform. Nodes are reachable only through the edge
# bastion (ProxyCommand lives in the inventory).
# ---------------------------------------------------------------------------

local-check:
	@if [ ! -f $(LOCAL_INV) ]; then echo "ERROR: $(LOCAL_INV) missing."; exit 1; fi
	@start=$$(date +%s); \
	while :; do \
		if $(LOCAL_PING) >/dev/null 2>&1; then \
			echo ""; \
			echo "All local hosts reachable after $$(($$(date +%s) - start))s."; \
			$(LOCAL_PING); \
			exit 0; \
		fi; \
		now=$$(date +%s); \
		if [ $$((now - start)) -ge $(WAIT_TIMEOUT) ]; then \
			echo ""; \
			echo "FAIL: local hosts not reachable after $(WAIT_TIMEOUT)s."; \
			$(LOCAL_PING); \
			exit 1; \
		fi; \
		printf "."; \
		sleep $(WAIT_INTERVAL); \
	done

local-prep: local-check
	$(LOCAL_ANS) ansible/playbooks/local-prep.yml

local-bootstrap: local-check
	$(LOCAL_ANS) ansible/playbooks/bootstrap.yml

local-haproxy: local-check
	$(LOCAL_ANS) ansible/playbooks/haproxy.yml

local-k8s: local-check
	$(LOCAL_ANS) ansible/playbooks/kubernetes.yml

local-cluster: local-check
	$(LOCAL_ANS) ansible/playbooks/cluster.yml

local-gateway: local-check
	$(LOCAL_ANS) ansible/playbooks/cluster-gateway.yml

# DNS-01 via Cloudflare: needs a real zone in the inventory AND the token
# in the environment. The token is written straight into a cert-manager
# Secret — it is never stored in the repo.
local-cert: local-check
	@if grep -q '^    enable_dns: true' $(LOCAL_INV) 2>/dev/null; then \
		if grep -q '^    dns_zone: "REPLACE_WITH_REAL_ZONE"' $(LOCAL_INV); then \
			echo "ERROR: dns_zone is still the placeholder in $(LOCAL_INV)."; \
			echo "Set a real Cloudflare-managed zone before running the cert phase."; \
			exit 1; \
		fi; \
		if [ -z "$$CLOUDFLARE_API_TOKEN" ]; then \
			echo "ERROR: enable_dns=true but CLOUDFLARE_API_TOKEN unset."; \
			echo "Export it (scope Zone:DNS:Edit) or flip enable_dns=false in $(LOCAL_INV)."; \
			exit 1; \
		fi; \
	fi
	$(LOCAL_ANS) ansible/playbooks/cluster-cert.yml

# Grafana is published on the public https listener, so its admin
# password comes from the environment — never from the repo.
local-observability: local-check
	@if [ -z "$$GRAFANA_ADMIN_PASSWORD" ]; then \
		echo "ERROR: GRAFANA_ADMIN_PASSWORD unset."; \
		echo "Export it (12+ chars) — Grafana is served on the public https listener."; \
		exit 1; \
	fi
	$(LOCAL_ANS) ansible/playbooks/cluster-observability.yml

local-demo: local-check
	$(LOCAL_ANS) ansible/playbooks/cluster-demo.yml

local-test:
	@$(MAKE) ANS_INV=$(LOCAL_INV) test

# Trim scratch files, shell history, apt cache and journal on all four VMs
# so they can be snapshotted.
local-cleanup: local-check
	$(LOCAL_ANS) ansible/playbooks/cleanup.yml

# Snapshot-grade cleanup: also purges the apt package indexes, clears kubelet
# pod logs and the helm cache, drops dead kubeadm bootstrap tokens, and
# removes the Exited container records left by pod restarts and node reboots
# (each one pins a containerd overlayfs snapshot).
#
# Container IMAGE pruning is deliberately NOT enabled here: `crictl rmi
# --prune` drops the images of any Deployment that is scaled to 0, which
# forces a full re-pull over the WireGuard tunnel on restore. Add
#   -e cleanup_prune_containerd_images=true
# to the cleanup.yml invocation if snapshot size matters more than restore
# speed.
local-cleanup-snapshot: local-check
	$(LOCAL_ANS) ansible/playbooks/cleanup.yml \
	  -e cleanup_purge_apt_lists=true \
	  -e cleanup_pod_logs=true \
	  -e cleanup_helm_cache=true \
	  -e cleanup_prune_exited_containers=true

local-all: local-prep local-bootstrap local-haproxy local-k8s local-cluster local-gateway local-cert local-observability local-demo
	@$(MAKE) local-test

clean:
	ansible -i $(ANS_INV) control_plane -m command \
	  -a 'kubectl --kubeconfig=/etc/kubernetes/admin.conf delete namespace demo monitoring --ignore-not-found' \
	  --become

destroy:
	$(TF) destroy -auto-approve

# Sweep AWS for orphan nexus-* resources when `destroy` leaves them behind
# (state reset, apply abandoned mid-flight, etc.).
nuke:
	$(TF) destroy -auto-approve || true
	./scripts/nuke-orphans.sh

help:
	@echo "Targets:"
	@echo "  check         - ansible ping all hosts with retry (default)"
	@echo "  terraform     - terraform init + apply"
	@echo "  inventory     - capture inventory from terraform output"
	@echo "  bootstrap     - bootstrap.yml (apt, base tools)"
	@echo "  k8s           - kubernetes.yml (k8s install)"
	@echo "  cni           - cluster.yml (Cilium)"
	@echo "  gateway       - cluster-gateway.yml (Gateway API + web Gateway)"
	@echo "  cert          - cluster-cert.yml (cert-manager + LE cert)"
	@echo "  observability - cluster-observability.yml (VictoriaMetrics stack)"
	@echo "  demo          - cluster-demo.yml (podinfo demo)"
	@echo "  haproxy       - haproxy.yml (HAProxy on edge)"
	@echo "  all           - full pipeline (terraform + ansible)"
	@echo "  clean         - delete demo + monitoring namespaces"
	@echo "  destroy       - terraform destroy"
	@echo "  nuke          - terraform destroy + sweep AWS for nexus-* orphans"
	@echo "  test          - HTTP GET probes against grafana/pod/demo via edge-01"
	@echo ""
	@echo "Local-VM lab (static inventory, no Terraform):"
	@echo "  local-check         - ping all local hosts with retry"
	@echo "  local-prep          - local-prep.yml (netplan: no DHCP search domain, route via edge)"
	@echo "  local-bootstrap     - bootstrap.yml against local.yml"
	@echo "  local-haproxy       - haproxy.yml (HAProxy on edge-01)"
	@echo "  local-k8s           - kubernetes.yml (containerd + kubelet)"
	@echo "  local-cluster       - cluster.yml (kubeadm init, Cilium, joins)"
	@echo "  local-gateway       - cluster-gateway.yml (Gateway API + web Gateway)"
	@echo "  local-cert          - cluster-cert.yml (cert-manager + LE, needs CLOUDFLARE_API_TOKEN)"
	@echo "  local-observability - cluster-observability.yml (VictoriaMetrics stack)"
	@echo "  local-demo          - cluster-demo.yml (podinfo demo)"
	@echo "  local-test          - HTTP GET probes via edge-01 (local inventory)"
	@echo "  local-cleanup       - cleanup.yml (scratch files, history, apt cache, journal)"
	@echo "  local-cleanup-snapshot - cleanup.yml + apt indexes, pod logs, helm cache, bootstrap tokens"
	@echo "  local-all           - full local pipeline"
	@echo ""
	@echo "Tunables (env or cmdline):"
	@echo "  WAIT_TIMEOUT   max seconds to wait for hosts (default 360)"
	@echo "  WAIT_INTERVAL  seconds between ping attempts (default 10)"
	@echo ""
	@echo "Examples:"
	@echo "  make terraform inventory             # build + capture"
	@echo "  make check WAIT_TIMEOUT=600          # verify SSH, wait up to 10min"
	@echo "  make bootstrap k8s cni               # bring up k8s"
	@echo "  make observability demo              # install apps"
	@echo "  make all                             # end-to-end rebuild"
	@echo "  make local-k8s local-cluster          # bring up the local-VM cluster"
