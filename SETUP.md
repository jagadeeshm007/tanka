# SETUP — Build This From Scratch

A complete, self-contained walkthrough of the ClickHouse-on-Kubernetes deployment in
this repo. Follow it top to bottom on a fresh machine and you will reproduce exactly
what we built: a **local Minikube** ClickHouse cluster deployed to **production
standards**.

Every tool is explained the first time it appears. Nothing here depends on any private
repository — the only external code we pull comes from public sources via `jb`.

---

## Table of Contents

1. [The big picture](#1-the-big-picture)
2. [Tools — what each one is and why](#2-tools--what-each-one-is-and-why)
3. [Phase 0 — Install the toolchain](#3-phase-0--install-the-toolchain)
4. [Phase 1 — Start Minikube](#4-phase-1--start-minikube)
5. [Phase 2 — Initialise the Tanka project](#5-phase-2--initialise-the-tanka-project)
6. [Phase 3 — Pull the ClickHouse CRD library](#6-phase-3--pull-the-clickhouse-crd-library)
7. [Phase 4 — Write the shared libraries](#7-phase-4--write-the-shared-libraries)
8. [Phase 5 — Define the environments](#8-phase-5--define-the-environments)
9. [Phase 6 — Install the operator (Helm via Tanka)](#9-phase-6--install-the-operator-helm-via-tanka)
10. [Phase 7 — Create the password Secret](#10-phase-7--create-the-password-secret)
11. [Phase 8 — Deploy and validate](#11-phase-8--deploy-and-validate)
12. [What we hardened and why](#12-what-we-hardened-and-why)
13. [Gotchas we hit (and the fixes)](#13-gotchas-we-hit-and-the-fixes)

---

## 1. The big picture

We want a ClickHouse database running on Kubernetes. Doing that by hand (writing
StatefulSets, Services, ConfigMaps, PVCs) is error-prone. Instead:

```
You write:   Jsonnet params   (tiny, per-environment)
                    │
   Tanka renders →  Kubernetes YAML
                    │
   applied to   →   Kubernetes (Minikube)
                    │
   watched by   →   Altinity ClickHouse Operator
                    │
   which creates →  ClickHouse pods + ClickHouse Keeper pods + Services + PVCs
```

Two layers of "declare, don't script":

- **The operator** turns a small `ClickHouseInstallation` (CHI) object into all the
  real Kubernetes resources.
- **Tanka + Jsonnet** turn small parameter files into that CHI object, without
  copy-pasting YAML between environments.

---

## 2. Tools — what each one is and why

**Docker** — builds and runs containers. Minikube uses it as the "machine" that hosts
the Kubernetes cluster. You don't call it directly much here; it runs underneath.

**Minikube** — a single-node Kubernetes cluster on your laptop. It's the "cluster" we
deploy into. Think of it as a real Kubernetes you can throw away and recreate.

**kubectl** — the command-line client for talking to any Kubernetes cluster (list
pods, read logs, apply YAML). Every other tool ultimately drives `kubectl`-style API
calls.

**Helm** — the de-facto package manager for Kubernetes. A "chart" is a templated
bundle of manifests (like an installer). We use Helm to install the **operator**,
because an operator is infrastructure you install once and upgrade rarely — Helm
tracks the release and makes upgrades/rollbacks clean.

**Jsonnet** — a small configuration language that produces JSON/YAML. Unlike raw YAML,
it has variables, functions, and imports, so you can build config without duplication.

**Tanka (`tk`)** — Grafana's tool that applies Jsonnet to Kubernetes. It adds the
concept of **environments** (each bound to a cluster + namespace) and the
`show / diff / apply` workflow. It also knows how to render Helm charts from inside
Jsonnet, so the operator install lives in the same declarative world as everything
else.

**jsonnet-bundler (`jb`)** — the dependency manager for Jsonnet (like `npm`/`go mod`).
It downloads public Jsonnet libraries into `vendor/` and pins them in a lock file.

**The Altinity ClickHouse Operator** — a controller that runs in the cluster and turns
`ClickHouseInstallation` (CHI) and `ClickHouseKeeperInstallation` (CHK) Custom
Resources into running ClickHouse and Keeper clusters.

**ClickHouse Keeper** — ClickHouse's built-in coordination service (a drop-in
replacement for ZooKeeper). Replicated tables use it to agree on what data exists.

---

## 3. Phase 0 — Install the toolchain

Install these (versions are what we used):

| Tool                     | Version  | Install hint                                                            |
| ------------------------ | -------- | ----------------------------------------------------------------------- |
| Docker                   | 24+      | distro package or Docker Desktop                                        |
| Minikube                 | v1.38+   | https://minikube.sigs.k8s.io/docs/start/                                |
| kubectl                  | v1.35+   | https://kubernetes.io/docs/tasks/tools/                                 |
| Helm                     | v3 or v4 | https://helm.sh/docs/intro/install/                                     |
| Tanka (`tk`)           | v0.38+   | `go install github.com/grafana/tanka/cmd/tk@latest`                   |
| jsonnet-bundler (`jb`) | v0.6+    | `go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest` |
| jq                       | any      | distro package                                                          |

Verify:

```bash
docker version ; minikube version ; kubectl version --client
helm version ; tk --version ; jb --version ; jq --version
```

---

## 4. Phase 1 — Start Minikube

```bash
minikube start --cpus=4 --memory=6g
minikube status                 # host/kubelet/apiserver should be Running
kubectl config current-context  # should print: minikube
kubectl get nodes               # one Ready node
kubectl get storageclass        # note the default: 'standard'
```

`standard` is Minikube's built-in dynamic storage (hostpath). We reference it by name
later for our PersistentVolumeClaims (PVCs).

---

## 5. Phase 2 — Initialise the Tanka project

```bash
mkdir clickhouse && cd clickhouse
tk init
```

`tk init` scaffolds:

- `lib/` — your own Jsonnet libraries
- `vendor/` — third-party libraries fetched by `jb`
- `jsonnetfile.json` / `jsonnetfile.lock.json` — `jb` dependency manifest + lock
- `lib/k.libsonnet` — the Kubernetes API types for Jsonnet (so you can write
  `k.core.v1.namespace.new(...)` etc.)
- `environments/default/` — a starter environment (we'll replace it)

We use a `{cloud}/{tier}/{component}` layout so each piece deploys independently:

```bash
rm -rf environments/default
# one environment per component; all bound to the 'minikube' context + 'clickhouse' ns
tk env add environments/local/development/core              --context-name=minikube --namespace=clickhouse
tk env add environments/local/development/clickhouse-operator --context-name=minikube --namespace=clickhouse-operator
tk env add environments/local/development/clickhouse-keeper --context-name=minikube --namespace=clickhouse
tk env add environments/local/development/clickhouse        --context-name=minikube --namespace=clickhouse
```

**Why `--context-name` instead of a server URL?** Minikube's IP can change between
restarts; the context name `minikube` always resolves to the right cluster via your
kubeconfig. Each environment's binding lives in its `spec.json`.

For the operator environment, edit its `spec.json` to add server-side apply — the
operator's CRDs are large and exceed the client-side annotation size limit:

```json
{ "spec": { "namespace": "clickhouse-operator", "applyStrategy": "server",
            "contextNames": ["minikube"] } }
```

---

## 6. Phase 3 — Pull the ClickHouse CRD library

To build a CHI object in Jsonnet with typed helpers, we pull the **public**,
auto-generated library for the operator's CRDs:

```bash
jb install github.com/jsonnet-libs/clickhouse-operator-libsonnet/0.25@main
```

This lands in `vendor/github.com/jsonnet-libs/clickhouse-operator-libsonnet/0.25/` and
is imported as:

```jsonnet
local chi = (import 'github.com/jsonnet-libs/clickhouse-operator-libsonnet/0.25/main.libsonnet')
            .clickhouse.v1.clickHouseInstallation;
```

> There is **no public library for the Keeper CRD**, so we build that object by hand
> (see `lib/keeper/main.libsonnet`). It's a small, stable structure — no generator
> needed.

Commit `jsonnetfile.lock.json` so everyone resolves the same versions.

---

## 7. Phase 4 — Write the shared libraries

The whole design principle: **libraries own structure + security; environment files
own only values.** Create these under `lib/` (full contents are in the repo):

### `lib/priority-class/priority.libsonnet`

A tiny factory for a `PriorityClass` (so DB pods schedule first and evict last).

### `lib/k8sutils/podAntiAffinity.libsonnet`

Returns a pod-anti-affinity term for a label — used to spread replicas across nodes.

### `lib/chutils/main.libsonnet`

The heart of the hardening. Exposes:

- `securityContext` — non-root uid/gid 101, `runAsNonRoot`, drop ALL capabilities,
  no privilege escalation, `RuntimeDefault` seccomp.
- `probes(port)` — startup + liveness + readiness HTTP probes on `/ping`.
- `CreatePVC` / `DataVolumeClaimTemplate` — disks (standalone vs operator-managed).
- `PodTemplate(params)` — assembles a ClickHouse pod template with the securityContext,
  probes, resources, optional anti-affinity / topology-spread / priorityClass.

### `lib/clickhouse/main.libsonnet`

`new(params)` → a complete, hardened `ClickHouseInstallation`: 1 shard × N replicas,
Keeper wiring, users (password from a Secret), Prometheus endpoint, an explicit
ClusterIP service, and an optional PodDisruptionBudget.

### `lib/keeper/main.libsonnet`

`new(params)` → a complete `ClickHouseKeeperInstallation`, built as a plain object
(no external CRD lib). Reuses the same non-root securityContext.

### `lib/netpol/main.libsonnet`

`new(params)` → three NetworkPolicies: default-deny ingress, allow intra-namespace +
operator, allow Prometheus scraping.

---

## 8. Phase 5 — Define the environments

Each environment file is now tiny — just values passed to a library.

`environments/local/development/core/main.jsonnet` — namespace, PriorityClass,
NetworkPolicies:

```jsonnet
local k = import 'k.libsonnet';
local priority = import 'priority-class/priority.libsonnet';
local netpol = import 'netpol/main.libsonnet';
{
  namespace: k.core.v1.namespace.new('clickhouse'),
  priorityClass: priority.new('high-priority', 1000, 'DB workloads').priorityClass,
  networkPolicies: netpol.new(),
}
```

`environments/local/development/clickhouse-keeper/main.jsonnet`:

```jsonnet
local keeper = import 'keeper/main.libsonnet';
keeper.new({
  image: 'clickhouse/clickhouse-keeper:25.8.29.51',
  replicas: 1, storage: '5Gi', storageClass: 'standard',
  requests: { cpu: '100m', memory: '256Mi' },
  limits:   { cpu: '500m', memory: '1Gi' },
})
```

`environments/local/development/clickhouse/main.jsonnet`:

```jsonnet
local clickhouse = import 'clickhouse/main.libsonnet';
clickhouse.new({
  name: 'clickhouse', cluster: 'clickhouse',
  keeperHost: 'keeper-clickhouse-keeper',           // {cluster}-{chk} naming
  image: 'clickhouse/clickhouse-server:25.8.29.51',
  replicas: 1, storage: '20Gi', storageClass: 'standard',
  requests: { cpu: '500m', memory: '1Gi' },
  limits:   { cpu: '2',    memory: '4Gi' },
  passwordSecret: { name: 'clickhouse-credentials', key: 'password' },
})
```

Preview any of them without touching the cluster:

```bash
tk show environments/local/development/clickhouse --dangerous-allow-redirect
```

---

## 9. Phase 6 — Install the operator (Helm via Tanka)

We install the operator from its official Helm chart, but drive Helm **through Tanka**
so it lives in the same declarative workflow.

Create `environments/local/development/clickhouse-operator/chartfile.yaml`:

```yaml
directory: charts
repositories:
  - name: altinity
    url: https://altinity.github.io/clickhouse-operator
requires:
  - chart: altinity/altinity-clickhouse-operator
    version: 0.27.3
version: 1
```

Vendor the chart (downloads it into `charts/`, which is git-ignored):

```bash
cd environments/local/development/clickhouse-operator && tk tool charts vendor && cd -
```

`environments/local/development/clickhouse-operator/main.jsonnet`:

```jsonnet
local tanka = import 'github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet';
local helm = tanka.helm.new(std.thisFile);
{
  clickhouse_operator: helm.template('clickhouse-operator', './charts/altinity-clickhouse-operator', {
    namespace: 'clickhouse-operator',
    values: { watchNamespaces: ['clickhouse'], crdHook: { enabled: false } },
    includeCrds: true,
  }),
}
```

`tanka-util` provides `helm.template()`; add it once with
`jb install github.com/grafana/jsonnet-libs/tanka-util@master`.

- `watchNamespaces: ['clickhouse']` — least privilege; the operator only manages our
  namespace.
- `crdHook: { enabled: false }` + `includeCrds: true` — install the CRDs directly
  rather than via the chart's hook job (which pulls `bitnami/kubectl:latest` and can
  hit rate limits).

---

## 10. Phase 7 — Create the password Secret

The ClickHouse `default` user must have a password, and that password must **never**
be in Git. We store it in a Kubernetes Secret and reference it from the CHI via
`valueFrom.secretKeyRef`.

`scripts/create-secret.sh` generates a random password (or takes
`CLICKHOUSE_PASSWORD`) and creates the Secret:

```bash
./scripts/create-secret.sh clickhouse minikube
# prints the generated password once — save it in a password manager
```

The CHI references it (already wired in `lib/clickhouse`):

```jsonnet
'default/password': { valueFrom: { secretKeyRef: { name: 'clickhouse-credentials', key: 'password' } } }
```

Add secret filenames to `.gitignore`.

---

## 11. Phase 8 — Deploy and validate

Order matters: **core → operator → keeper → clickhouse**.
(core defines the PriorityClass the pods reference; the operator installs the CRDs;
ClickHouse coordinates through Keeper.)

```bash
tk apply environments/local/development/core             --auto-approve=always
tk apply environments/local/development/clickhouse-operator --auto-approve=always
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=altinity-clickhouse-operator -n clickhouse-operator --timeout=90s

tk apply environments/local/development/clickhouse-keeper --auto-approve=always
kubectl wait --for=jsonpath='{.status.status}'=Completed chk/clickhouse-keeper -n clickhouse --timeout=180s

tk apply environments/local/development/clickhouse        --auto-approve=always
kubectl wait --for=jsonpath='{.status.status}'=Completed chi/clickhouse -n clickhouse --timeout=180s
```

(The repo's `Makefile` wraps all of this: `make create-secret && make apply-all`.)

Validate end-to-end:

```bash
POD=$(kubectl get pod -n clickhouse -l clickhouse.altinity.com/chi=clickhouse -o jsonpath='{.items[0].metadata.name}')
PASS=$(kubectl get secret clickhouse-credentials -n clickhouse -o jsonpath='{.data.password}' | base64 -d)

# 1. passwordless access must be REJECTED
kubectl exec -n clickhouse $POD -- clickhouse-client --query "SELECT 1"        # expect: auth error

# 2. with the password it works, and runs as non-root
kubectl exec -n clickhouse $POD -- clickhouse-client --password "$PASS" --query "SELECT version()"
kubectl exec -n clickhouse $POD -- id                                          # expect: uid=101(clickhouse)

# 3. Keeper is connected
kubectl exec -n clickhouse $POD -- clickhouse-client --password "$PASS" --query \
  "SELECT host, port FROM system.zookeeper_connection"

# 4. a replicated table round-trips
kubectl exec -n clickhouse $POD -- clickhouse-client --password "$PASS" --multiquery --query \
  "CREATE DATABASE IF NOT EXISTS test;
   CREATE TABLE IF NOT EXISTS test.t (id UInt64, ts DateTime)
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/t','{replica}') ORDER BY (ts,id);
   INSERT INTO test.t VALUES (1, now());
   SELECT * FROM test.t;"
```

Or simply: `make validate`.

---

## 12. What we hardened and why

| Hardening                                                  | Why it matters                                                   | Where                                            |
| ---------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------ |
| Run as non-root (uid 101, drop caps, no priv-esc, seccomp) | A compromised process can't act as root or escalate              | `lib/chutils`                                  |
| Password from a Secret; passwordless rejected              | No open admin access; no plaintext creds in Git                  | `lib/clickhouse`, `scripts/create-secret.sh` |
| Startup + liveness + readiness probes                      | K8s restarts hung pods and pulls not-ready pods from the Service | `lib/chutils`                                  |
| Pinned operator + image versions                           | Reproducible; avoids surprise breakage from floating tags        | env files,`chartfile.yaml`                     |
| Default-deny NetworkPolicies                               | Only the operator and monitoring can reach the DB                | `lib/netpol`                                   |
| PriorityClass, and PDB/anti-affinity as params             | Correct scheduling and HA behaviour under pressure               | `lib/*`                                        |
| Prometheus endpoint (:9363)                                | Observability is built in, not bolted on                         | `lib/clickhouse`                               |

> NetworkPolicies are **objects** on Minikube but only **enforced** by a CNI that
> supports them (e.g. GKE Dataplane V2 / Cilium / Calico). They're here so local
> mirrors real clusters.

---

## 13. Gotchas we hit (and the fixes)

**Keeper cluster name too long.** The CHK CRD limits `cluster.name` to 15 bytes;
`clickhouse-keeper` (16) is rejected. Use a short name like `keeper`.

**ClickHouse couldn't resolve the Keeper host.** The operator names the Keeper service
`{clusterName}-{chkName}` → `keeper-clickhouse-keeper`. The CHI's `zookeeperHost` must
match that exactly.

**Keeper CrashLoop: `UNKNOWN_SETTING: use_xid_64`.** Operator 0.27.3 injects the
`use_xid_64` Keeper setting (and an `http_control` readiness endpoint) that only exist
in ClickHouse **25.x**. Pinning to an older LTS (24.8) crash-loops Keeper.
**Fix: match the image to the operator — we use `25.8.29.51`.**

**Custom Keeper probes broke health.** Operator 0.27.x renders Keeper's own
`ruok`/`http_control` probes. Defining our own overrode them. **Fix: no container
probes for Keeper** (ClickHouse server still uses our HTTP `/ping` probes).

**`TABLE_IS_READ_ONLY` after resetting Keeper.** A ReplicatedMergeTree stores metadata
in Keeper; if the Keeper volume is recreated, existing tables lose that metadata and go
read-only. **Fix: drop and recreate the affected tables.**

**Migrating the operator from `helm install` to Tanka.** The CRDs are installed by the
operator's hook job, not owned by the Helm release — so `helm uninstall` does **not**
cascade-delete the CRDs (or your CHI/CHK). That makes it safe to hand operator
ownership over to Tanka.
