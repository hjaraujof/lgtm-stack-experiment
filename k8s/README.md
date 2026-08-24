# The Kubernetes plane

The same LGTM stack that `docker-compose.yml` runs, expressed as plain Kubernetes objects
in a hand-written Helm chart.

**Nothing at the repository root is replaced.** The Compose file and the EC2 Terraform still
work and still describe a live deployment. This is a third way to run the same thing, built
to be read.

```text
k8s/
├── kind/kind-cluster.yaml      three-node local cluster
├── charts/lgtm-stack/          the chart
│   ├── files/                  synced copy of ../../config
│   ├── scripts/                synced copy of ../../scripts
│   ├── values.yaml             defaults + the reasoning
│   ├── values-kind.yaml        local overlay
│   └── values-eks.yaml         AWS overlay
├── images/init-tools/          toolchain image for the init jobs
├── scripts/                    helpers that are not part of the chart
└── Makefile                    every command below

terraform/eks/                  a SEPARATE OpenTofu root module for the cluster
```

---

## The one idea to take away

**A Kubernetes Service name replaces a Docker Compose service name.** Both are DNS names on
a private network. Because the Services here are called `loki`, `tempo`, `mimir` and
`grafana`, every existing config file works unchanged — `http://mimir:9009/api/v1/push`
resolves in both worlds.

That is why this chart has no `fullnameOverride` and why one release per namespace is the
accepted limit. The alternative is editing every config file to match a generated name.

---

## Quick start

Run everything from the repository root.

```bash
make -C k8s up        # cluster + image + controllers + secrets + install
make -C k8s test      # end-to-end: send OTLP, read it back out of Mimir
make -C k8s status
make -C k8s destroy   # delete the whole cluster
```

`up` is five steps. Run them separately when one fails:

```bash
make -C k8s cluster    # kind create cluster
make -C k8s image      # build init-tools and load it into kind
make -C k8s addons     # ingress-nginx + cert-manager
make -C k8s secrets    # generate the local Secrets
make -C k8s install    # helm upgrade --install
```

### Static gates, no cluster needed

```bash
make -C k8s check-sync       # the chart copy matches config/ and scripts/
make -C k8s lint             # helm lint
make -C k8s validate         # every object against the Kubernetes schema
make -C k8s verify-configs   # each backend's OWN validator, on the RENDERED config
```

`verify-configs` is the one that matters most. `helm lint` checks the chart; it never opens
the YAML inside a ConfigMap to ask whether Loki would still start. Two of these configs are
transformed rather than copied, so that gap is real.

---

## Compose to Kubernetes, object by object

| docker-compose.yml | Kubernetes | Why |
|---|---|---|
| `loki`, `tempo`, `mimir` + named volume | StatefulSet + `volumeClaimTemplates` + Service | A StatefulSet gives each pod a stable name and its own disk. A Deployment cannot. |
| `grafana` + `grafana-data` | StatefulSet, 1 replica | Grafana owns a SQLite file. Two replicas on one volume is corruption, not scale. |
| `otel-collector` (OTLP) | StatefulSet + Service | The disk-backed sending queue is state. |
| `otel-collector` (`hostmetrics`) | **DaemonSet** | A gateway pod sees one node and would report its CPU as the cluster's. |
| `init`, `init-loki`, `init-otelcol-queue` | `securityContext.fsGroup` | Kubernetes chowns the volume itself. All three chown containers disappear. |
| `grafana-init` | Job, `helm.sh/hook: post-install` | Run once, after Grafana answers, re-runnable. |
| `mimir-am-init` | Deployment | It is a loop with its own sleep, so it stays one. |
| config bind mounts | ConfigMap + `checksum/config` annotation | Without the annotation a config change never restarts the pod. |
| `config/mimir/rules:ro` | ConfigMap, read-only | `helm upgrade` replaces `git pull` as the deploy. |
| `.env` passwords | a mounted **file**, never a value | See "Secrets" below. |
| `nginx` + `certbot` (2 services, 5 scripts) | Ingress + cert-manager | About 20 lines replace the pair. |
| `mem_limit: 6g` | `resources.limits.memory` | `limit_percentage` resolves against the cgroup in both. |
| `depends_on` | readiness probes | Kubernetes has no start order. A pod retries until its dependency answers. |
| EC2 instance IAM role | Pod Identity or IRSA | The permission belongs to a ServiceAccount, not to the machine. |

### Three traps, and the answer to each

- **Distroless images have no shell.** Compose drops every healthcheck for this reason.
  Kubernetes does not shell out — kubelet performs the `httpGet` itself, from outside the
  container. The constraint simply does not apply.
- **Two Mimir instances must never share a bucket and a prefix.** Mimir cannot see the other
  instance, so it does not refuse. Both compact over the same objects and metrics are lost
  silently. `terraform/eks/` therefore creates its own buckets.
- **A ConfigMap change does not restart anything.** Hence the checksum annotation on every
  workload.

---

## Secrets

**This chart creates no Secret.** Every one is referenced by name and must already exist, so
no password reaches git, a values file, a CI log, or `helm get values`.

The ladder, worst to best:

| Tier | Mechanism | |
|---|---|---|
| 1 | a literal in `values.yaml`, committed | never |
| 2 | `kubectl create secret` by hand | no secret in git, but no rotation and no audit |
| 3 | SOPS or Sealed Secrets | an encrypted blob is safe in git |
| 4 | Secrets Store CSI driver, or External Secrets Operator | the external store is the truth |
| 5 | Pod Identity or IRSA — no credential at all | nothing to leak, nothing to rotate |

Two facts decide the tier. A Kubernetes Secret is **base64, not encryption** — anyone with
`get secrets` in the namespace reads it. And a secret a human types once is a secret nobody
rotates.

Where this chart sits:

- **Tempo and Mimir against S3 — tier 5.** The configs name a bucket and never name a
  caller. `terraform/eks/identity.tf` supplies the identity. No key exists.
- **Grafana on EKS — tier 4.** The Secrets Store CSI driver reads AWS Secrets Manager with
  the pod's own identity and mounts the password as a **file**. No Kubernetes Secret is
  created, so nothing enters etcd. It is the same secret path `user_data.tpl` reads at boot,
  so one rotation reaches both planes.
- **MinIO and Grafana on kind — tier 2, correctly.** A throwaway cluster.
  `k8s/scripts/create-secrets.sh` **generates** the values; nothing is written down.

Grafana reads a **file** in both planes, through the `__FILE` suffix that every `GF_`
variable accepts. Only the source of that file differs. The container configuration is
identical, so the local cluster exercises the real mechanism.

**One tier higher: delete the credential.** A Grafana admin password exists only because a
login form exists. `grafana.auth.oauth` turns on SSO and `disableLoginForm`, after which the
built-in admin is break-glass only.

---

## What the chart does not install

The chart deploys the stack. It does not install the controllers the stack assumes, and each
absence fails in its own confusing way:

| Controller | Symptom when missing |
|---|---|
| ingress-nginx | The Ingress object exists, validates, and routes nothing. |
| cert-manager | `no matches for kind "ClusterIssuer"`. |
| EBS CSI driver (EKS) | Every pod stays Pending. The error is on the PVC, never on the pod. |
| Secrets Store CSI driver (EKS) | `no matches for kind "SecretProviderClass"`. |

`make -C k8s addons` installs the first two on kind. `terraform/eks/` enables the third.

---

## AWS

`terraform/eks/` is a **separate OpenTofu root module with its own state key**. A separate
module means one `tofu apply` can never touch both planes.

```bash
tofu -chdir=terraform/eks init
tofu -chdir=terraform/eks validate
tofu -chdir=terraform/eks plan
```

It creates its own VPC and two private subnets, because EKS requires two availability zones
and the root `main.tf` creates one public subnet.

`var.use_pod_identity` picks the identity mechanism:

- **true (default)** — EKS Pod Identity. AWS's current recommendation for a new cluster. No
  OIDC provider, no per-cluster trust policy, and the chart needs no annotation.
- **false** — IRSA. Portable: any OIDC provider, cross-account, outside EKS. It needs the
  `eks.amazonaws.com/role-arn` annotation on the ServiceAccount.

Both are tier 5. Choose on portability, not on safety.

> The ServiceAccount name must match. The chart names it `<release>-lgtm`, so
> `helm install lgtm` yields `lgtm-lgtm`, which is the module's default. A mismatch does not
> fail the apply — the pods simply get no identity, and the first symptom is an
> `AccessDenied` from S3 minutes later.

---

## Why the configs are copied into the chart

Helm cannot read a file outside the chart directory. `.Files.Get "../../config/x"` returns
nothing, silently.

So `config/` and `scripts/` are copied into `charts/lgtm-stack/files/` and
`charts/lgtm-stack/scripts/`. `make -C k8s sync-config` refreshes them and
`make -C k8s check-sync` fails on drift, in the working tree and in CI. The originals stay
the single source of truth.

Each backend ConfigMap then takes one of two paths:

- **no override** — the file is embedded byte for byte, comments and all.
- **an override** — the file is parsed, the override from `values.yaml` is deep-merged, and
  the result is re-emitted. The ConfigMap loses the comments; `config/` does not.

Verbatim is the default. A patch is deliberate and visible in `helm template`.

> Loki has no override on purpose. `config/loki-config.yaml` contains `from: 2024-01-01`,
> and a YAML round trip would re-emit that as a full timestamp that Loki rejects. Moving
> Loki to object storage is a dated schema-period migration, not a chart value.

---

## Next exercises

The chart is deliberately a monolith per component. Each of these is a real step up:

1. Split Mimir into its components, as the upstream `mimir-distributed` chart does.
2. Put a `loadbalancing` exporter in front of the collector, keyed on trace ID, and then
   raise `collector.replicas` above one.
3. Turn on `networkPolicy` and find out which flows you forgot.
4. Move Grafana's database to Postgres and run it as a Deployment with several replicas.
5. Replace `helm upgrade` with Argo CD or Flux, and make git the deploy again — which is
   what `git pull` already is on the Compose plane.
