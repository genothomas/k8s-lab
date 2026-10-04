# k8s-lab orchestration.
# Run `make help` for the full list.

ANS_INV := ansible/inventory/hosts.yml
ANS     := ansible-playbook -i $(ANS_INV)
PING    := ansible -i $(ANS_INV) all -m ping
TF      := terraform -chdir=terraform

# Wait time for hosts after terraform apply / reboot. Override cmdline.
WAIT_TIMEOUT  ?= 360
WAIT_INTERVAL ?= 10

.PHONY: all help check ping terraform inventory bootstrap k8s cni gateway cert observability demo haproxy clean destroy nuke wait-ready test

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
