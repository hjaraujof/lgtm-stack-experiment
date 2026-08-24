# Kubernetes deployment of the LGTM stack with Helm

## Context

This repository runs the LGTM stack in two places today. `docker-compose.yml` runs it
locally and on one EC2 host. The HCL files at the repository root (`main.tf`,
`s3-backends.tf`, `bootstrap.tf`, `alerting.tf`, `user_data.tpl`) build that host.

The goal is a third deployment plane: Kubernetes, through hand-written Helm charts. The
purpose is to learn Kubernetes. Therefore the plan writes each Kubernetes object
explicitly instead of consuming an upstream chart.

Constraint from the user: **do not delete the HCL files.** This plan adds a new
Terraform root module in a new directory. It changes no existing HCL file.

Decisions taken with the user:

- Charts are hand-written for Loki, Tempo, Mimir, Grafana and the OTel Collector.
- Two targets: a local `kind` cluster and an AWS EKS cluster.
- MinIO runs in the cluster as the S3-compatible backend.

Verified tooling on this machine: `kubectl` 1.35.4, `helm` 4.1.4, `kind` 0.31.0,
`docker`, `tofu`. `kubeconform` is absent and the plan installs it.

---

## The core idea

**A Kubernetes Service name replaces a Docker Compose service name.** Both are DNS
names on a private network. If the Service objects carry the names `loki`, `tempo`,
`mimir` and `grafana`, then every config file in `config/` keeps working without an
edit, because `http://mimir:9009` resolves in both worlds.

That single property decides the design. The charts therefore load the existing config
files verbatim into ConfigMaps. Only three values change for Kubernetes: the object
storage endpoint, the bucket names, and the Loki storage backend.

---

## Object mapping

Read this table first. It is the whole migration.

| docker-compose.yml | Kubernetes | Why |
|---|---|---|
| `loki`, `tempo`, `mimir` + named volume | StatefulSet + `volumeClaimTemplates` + headless Service + ClusterIP Service | A StatefulSet gives each pod a stable name and its own persistent disk. A Deployment cannot. |
| `grafana` + `grafana-data` | StatefulSet (1 replica) + ClusterIP Service | Grafana holds a SQLite database on disk. |
| `otel-collector` (OTLP receivers) | StatefulSet (gateway) + ClusterIP Service | The `file_storage/queue` extension needs a private disk per pod. |
| `otel-collector` (`hostmetrics` receiver) | **separate DaemonSet** with `hostPath: /` at `/hostfs` | A Deployment pod sees one node. Host metrics need one agent on every node. This is the one pipeline that must split. |
| `init`, `init-loki`, `init-otelcol-queue` (chown 10001) | `securityContext.fsGroup: 10001` | Kubernetes chowns a mounted volume itself. All three init containers disappear. |
| `grafana-init` (one-shot) | Job with `helm.sh/hook: post-install,post-upgrade` | Helm runs the hook after Grafana is ready and reports the result. |
| `mimir-am-init` (long loop, 60 s) | Deployment, 1 replica | The reconciler is a long-running loop, so it stays one. |
| `./config/*.yaml:/etc/...` bind mount | ConfigMap + volume mount | |
| `./config/mimir/rules:/etc/mimir/rules:ro` | ConfigMap, mounted read-only | `ruler_storage.backend=local` keeps its meaning. `helm upgrade` replaces `git pull` as the deploy. |
| `.env` Grafana passwords | Secret, injected with `envFrom` | On EKS the External Secrets Operator reads Secrets Manager. |
| `nginx` + `certbot` (2 services, 5 scripts) | Ingress + cert-manager `ClusterIssuer` | About 20 lines replace the whole TLS pair. |
| `mem_limit: 6g` | `resources.limits.memory: 6Gi` | The collector's `limit_percentage: 75` still resolves against the cgroup. The semantics carry over exactly. |
| `depends_on` | readiness probes + retries | Kubernetes has no start order. A pod retries until its dependency answers. |
| host ports 3100 / 3200 / 9009 | ClusterIP only, plus `kubectl port-forward` | |
| EC2 security group rules | NetworkPolicy (optional, phase 6) | |
| Route53 record `otel-collector.internal.example.com` | `otel-collector.lgtm.svc.cluster.local`, plus an internal load balancer on EKS | |
| EC2 instance IAM role | IRSA: an annotated ServiceAccount | |

Three known traps, and the answer to each:

- **Distroless images have no shell.** The compose file drops every healthcheck for this
  reason. Kubernetes does not need a shell: use `httpGet` probes against `/ready` on
  Loki, Tempo and Mimir, and `/api/health` on Grafana.
- **Two Mimir instances must never share a bucket and a prefix.** Mimir refuses to start,
  and worse, a shared prefix corrupts blocks. The EKS module therefore creates **new**
  buckets. It does not reuse the buckets in `s3-backends.tf`.
- **A config change must restart the pod.** A ConfigMap update alone does not restart
  anything. Every workload template carries a `checksum/config` pod annotation.

---

## Files to add

Nothing existing is deleted. Two new top-level directories.

```text
k8s/
  kind/kind-cluster.yaml            # 1 control plane, 2 workers, ports 80/443 mapped
  charts/lgtm-stack/
    Chart.yaml                      # dependency: minio (upstream), condition-gated
    values.yaml                     # defaults
    values-kind.yaml                # MinIO, self-signed TLS, small resources
    values-eks.yaml                 # real S3 + IRSA, Let's Encrypt, real resources
    files/                          # synced copy of ../../../config -- see below
    templates/
      _helpers.tpl                  # name, labels, checksum helpers
      configmap-backends.yaml       # loki, tempo, mimir configs
      configmap-collector.yaml
      configmap-mimir-rules.yaml
      configmap-grafana-provisioning.yaml
      secret-grafana.yaml
      loki.yaml  tempo.yaml  mimir.yaml
      grafana.yaml
      otel-collector.yaml           # gateway StatefulSet
      otel-agent.yaml               # hostmetrics DaemonSet
      mimir-am-reconciler.yaml
      job-grafana-init.yaml
      ingress.yaml
      serviceaccounts.yaml
      tests/test-pipeline.yaml      # helm test
  Makefile                          # up, down, sync-config, lint, smoke
  README.md
terraform/eks/                      # NEW root module, its own state key
  main.tf  vpc.tf  eks.tf  irsa.tf  buckets.tf  variables.tf  outputs.tf
```

### The config duplication problem, and the chosen answer

Helm reads a file only from inside the chart directory. `.Files.Get "../../config/x"`
fails. Three options exist. The chosen one is a **synced copy plus a drift gate**:

- `make sync-config` copies `config/` to `k8s/charts/lgtm-stack/files/`.
- A CI job runs the sync and then `git diff --exit-code`. A drifted copy fails the build.

This keeps `config/` the single source of truth and keeps the failure loud. A symlink is
the alternative, but Helm's treatment of a symlink outside the chart root is
version-dependent and unverified here.

---

## Phases

Each phase ends in a command that proves it works.

### Phase 0 — cluster and tooling

Write `k8s/kind/kind-cluster.yaml` and the `Makefile`. Install `kubeconform` through
`mise`. Create the cluster and confirm three nodes are `Ready`.

### Phase 1 — storage and the three backends

Add the chart skeleton, the MinIO dependency, the ConfigMaps, and the Loki, Tempo and
Mimir StatefulSets. Edit the three config files in `config/` for object storage:

- `config/loki-config.yaml`: activate the commented `s3` path at lines 57-66.
- `config/tempo-config.yaml` and `config/mimir-config.yaml`: the `endpoint`, `region`
  and bucket values become Helm values.

> Warning: these three edits touch files that the EC2 deployment also uses. Keep the AWS
> values as the defaults in `values-eks.yaml`, so the EC2 plane reads the same numbers.

Proof: `kubectl port-forward svc/mimir 9009`, then `curl localhost:9009/ready`.

### Phase 2 — Grafana

Add the Grafana StatefulSet, the provisioning ConfigMaps, the Secret and the
`grafana-init` Job. The Job reads passwords from the Secret, so it never calls AWS.

Proof: `curl localhost:3000/api/health`, then confirm three datasources answer.

### Phase 3 — the collector, split in two

Add the gateway StatefulSet and the `hostmetrics` DaemonSet. Split
`config/otel-collector-config.yaml` into two ConfigMaps at the pipeline level. The
gateway keeps `otlp`, `spanmetrics`, `servicegraph`, `tail_sampling` and the three
exporters. The agent keeps `hostmetrics` and the Mimir remote-write exporter only.

Proof: port-forward 4318 and run the existing `scripts/send-test-telemetry.sh`. Then
query each backend. The existing script is the end-to-end test. Do not write a new one.

### Phase 4 — ingress and TLS

Install `ingress-nginx` and `cert-manager` as cluster add-ons. Add `ingress.yaml`. Use a
self-signed `ClusterIssuer` on kind and a Let's Encrypt HTTP-01 issuer on EKS.

Proof: `curl -k https://grafana.localtest.me/api/health` through the mapped port.

### Phase 5 — tests and CI

Add a `helm test` pod that sends one trace and then queries Tempo for it. Add
`.github/workflows/helm-check.yml`: `helm lint`, `helm template | kubeconform`, the
config drift gate, and a `kind` smoke install. Follow the repository's existing rule and
pair each validator with a positive control that asserts it rejects a broken chart.

### Phase 6 — EKS

Add `terraform/eks/` as a **separate root module with its own state key**. A separate
module means one `tofu apply` never touches both planes. It contains its own VPC and two
private subnets, because EKS needs two availability zones and `main.tf` creates one
public subnet only. It also contains the OIDC provider, the IRSA roles for Tempo and
Mimir, and **new** trace and metric buckets.

Proof: `tofu plan` in the new directory, then `helm install -f values-eks.yaml`.

---

## Verification

```bash
# Phase 0
kind create cluster --config k8s/kind/kind-cluster.yaml
kubectl get nodes

# Static gates, before any install
helm lint k8s/charts/lgtm-stack
helm template lgtm k8s/charts/lgtm-stack -f k8s/charts/lgtm-stack/values-kind.yaml | kubeconform -strict -summary

# Install
helm dependency update k8s/charts/lgtm-stack
helm install lgtm k8s/charts/lgtm-stack -n lgtm --create-namespace -f k8s/charts/lgtm-stack/values-kind.yaml
kubectl -n lgtm wait --for=condition=ready pod --all --timeout=300s

# End-to-end, with the scripts this repository already has
kubectl -n lgtm port-forward svc/otel-collector 4318:4318 &
./scripts/send-test-telemetry.sh
kubectl -n lgtm port-forward svc/grafana 3000:3000 &
curl -s localhost:3000/api/health | jq .

# Helm's own test hook
helm test lgtm -n lgtm

# Remove everything
helm uninstall lgtm -n lgtm && kind delete cluster --name lgtm
```

The existing repository tests stay valid and must still pass, because the rule files do
not change:

```bash
docker run --rm -v "$PWD:/w:ro" -w /w --entrypoint promtool prom/prometheus:v3.1.0 \
  test rules tests/mimir-rules/*.test.yaml
python3 tests/scripts/test-am-reconcile.py
```

---

## Risks

- **The collector split changes the telemetry shape.** Host metrics arrive from many
  agents, not one host. A dashboard that assumes one host needs a `by (node)` clause.
- **`tail_sampling` is stateful.** All spans of one trace must reach the same collector
  pod. With more than one gateway replica, a load balancer that spreads spans breaks
  sampling. The plan therefore pins the gateway to one replica and records the reason.
- **MinIO is not S3.** It is close, but a path-style or region difference can appear
  only at runtime. Phase 1 proves the write path with a real query.
- **Helm 4 is new.** Some Helm 3 chart idioms changed. Expect a lint surprise.
