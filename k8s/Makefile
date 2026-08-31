# Kubernetes plane. Run every target from the repository root as `make -C k8s <target>`.
#
# This Makefile is the executable half of k8s/README.md. If a command here and a command
# there disagree, this file is right and the README is stale.

# Resolved from PATH, not hardcoded to /bin/bash: NixOS has no /bin/bash.
SHELL      := $(shell command -v bash)
.SHELLFLAGS := -eu -o pipefail -c

ROOT       := $(CURDIR)/..
CHART      := $(CURDIR)/charts/lgtm-stack
RELEASE    ?= lgtm
NAMESPACE  ?= lgtm
CLUSTER    ?= lgtm
VALUES     ?= $(CHART)/values-kind.yaml
INIT_IMAGE ?= lgtm-init-tools:local

.DEFAULT_GOAL := help

.PHONY: help
help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-16s %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------------------
# Config sync
# ---------------------------------------------------------------------------------------
# HELM CANNOT READ A FILE OUTSIDE THE CHART DIRECTORY. .Files.Get "../../config/x" returns
# nothing, silently. So the configs are copied in, and `check-sync` makes the copy a gate
# rather than a hope. config/ and scripts/ stay the single source of truth.

.PHONY: sync-config
sync-config: ## Copy config/ and scripts/ into the chart
	rsync -a --delete "$(ROOT)/config/" "$(CHART)/files/"
	rsync -a --delete --include='*.sh' --exclude='*' "$(ROOT)/scripts/" "$(CHART)/scripts/"
	@echo "OK: chart files synced"

.PHONY: check-sync
check-sync: ## Fail if the chart copy has drifted from config/ or scripts/
	@diff -r "$(ROOT)/config" "$(CHART)/files" \
	  || { echo "ERROR: chart files/ has drifted from config/. Run: make -C k8s sync-config"; exit 1; }
	@for f in "$(ROOT)"/scripts/*.sh; do \
	    diff -q "$$f" "$(CHART)/scripts/$$(basename $$f)" >/dev/null \
	      || { echo "ERROR: chart scripts/ has drifted from scripts/. Run: make -C k8s sync-config"; exit 1; }; \
	  done
	@echo "OK: chart copy matches config/ and scripts/"

# ---------------------------------------------------------------------------------------
# Static gates. These run without a cluster.
# ---------------------------------------------------------------------------------------

.PHONY: lint
lint: check-sync ## helm lint
	helm lint "$(CHART)" -f "$(VALUES)"

.PHONY: template
template: check-sync ## Render every object to stdout
	@helm template "$(RELEASE)" "$(CHART)" -n "$(NAMESPACE)" -f "$(VALUES)"

.PHONY: validate
validate: check-sync ## Render, then check every object against the Kubernetes schema
	helm template "$(RELEASE)" "$(CHART)" -n "$(NAMESPACE)" -f "$(VALUES)" \
	  | kubeconform -strict -summary -ignore-missing-schemas

# THE RENDERED CONFIG IS ALSO A CONFIG, and it is the one the pods read. `helm lint` checks
# the chart; it says nothing about whether the YAML inside a ConfigMap still loads. This
# target extracts each rendered config and runs the SAME validator the repository already
# runs in .github/workflows/config-check.yml.
.PHONY: verify-configs
verify-configs: check-sync ## Run each backend's own validator against the RENDERED config
	@tmp=$$(mktemp -d); \
	helm template "$(RELEASE)" "$(CHART)" -n "$(NAMESPACE)" -f "$(VALUES)" > "$$tmp/all.yaml"; \
	python3 "$(CURDIR)/scripts/extract-configs.py" "$$tmp/all.yaml" "$$tmp"; \
	docker run --rm -v "$$tmp/loki-config.yaml:/c.yaml:ro" --entrypoint loki \
	  grafana/loki:3.7.3 -config.file=/c.yaml -verify-config; echo "OK: loki"; \
	docker run --rm -v "$$tmp/mimir-config.yaml:/c.yaml:ro" --entrypoint mimir \
	  grafana/mimir:3.1.2 -config.file=/c.yaml -modules >/dev/null; echo "OK: mimir"; \
	docker run --rm -v "$$tmp/tempo-config.yaml:/c.yaml:ro" --entrypoint /tempo \
	  grafana/tempo:3.0.2 -config.file=/c.yaml -config.verify=true; echo "OK: tempo"; \
	docker run --rm -v "$$tmp/otel-collector-config.yaml:/c.yaml:ro" -v /:/hostfs:ro \
	  otel/opentelemetry-collector-contrib:0.142.0 validate --config=/c.yaml; echo "OK: collector gateway"; \
	docker run --rm -v "$$tmp/otel-agent-config.yaml:/c.yaml:ro" -v /:/hostfs:ro \
	  -e K8S_NODE_NAME=ci \
	  otel/opentelemetry-collector-contrib:0.142.0 validate --config=/c.yaml; echo "OK: collector agent"; \
	rm -rf "$$tmp"

# ---------------------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------------------

.PHONY: cluster
cluster: ## Create the kind cluster
	kind create cluster --config "$(CURDIR)/kind/kind-cluster.yaml"

.PHONY: image
image: ## Build the init-tools image and load it into kind
	docker build -t "$(INIT_IMAGE)" "$(CURDIR)/images/init-tools"
	kind load docker-image "$(INIT_IMAGE)" --name "$(CLUSTER)"

.PHONY: addons
addons: ## Install ingress-nginx and cert-manager
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx wait --for=condition=available deploy/ingress-nginx-controller --timeout=300s
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm upgrade --install cert-manager jetstack/cert-manager \
	  -n cert-manager --create-namespace --set crds.enabled=true
	kubectl -n cert-manager wait --for=condition=available deploy --all --timeout=300s

.PHONY: secrets
secrets: ## Create the local Secrets, with generated values. LOCAL CLUSTERS ONLY.
	"$(CURDIR)/scripts/create-secrets.sh" "$(NAMESPACE)"

.PHONY: install
install: check-sync ## Install or upgrade the release
	helm upgrade --install "$(RELEASE)" "$(CHART)" \
	  -n "$(NAMESPACE)" --create-namespace -f "$(VALUES)" --wait --timeout 10m

.PHONY: test
test: ## Run the end-to-end helm test
	helm test "$(RELEASE)" -n "$(NAMESPACE)" --logs

.PHONY: status
status: ## Show what is running
	kubectl -n "$(NAMESPACE)" get pods,svc,pvc,ingress

.PHONY: uninstall
uninstall: ## Remove the release. PersistentVolumeClaims SURVIVE this on purpose.
	helm uninstall "$(RELEASE)" -n "$(NAMESPACE)"
	@echo "NOTE: a StatefulSet's PVCs are NOT deleted with the release. That is the default"
	@echo "and it is deliberate - it is what stops an accidental uninstall destroying data."
	@echo "To wipe them: kubectl -n $(NAMESPACE) delete pvc --all"

.PHONY: destroy
destroy: ## Delete the whole kind cluster
	kind delete cluster --name "$(CLUSTER)"

.PHONY: up
up: cluster image addons secrets install ## Create everything from nothing
