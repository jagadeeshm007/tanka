# ClickHouse on Kubernetes (Local, Production-Grade)

A **local Minikube** ClickHouse deployment built to **production standards** — the
right way to learn the stack. Managed with Tanka (Jsonnet), the Altinity ClickHouse
Operator, and ClickHouse Keeper. Structured so the same libraries would drive a real
GKE deployment with only a new environment file.

> Scope: this repo deploys **local/development** only. It is deliberately built with
> production-grade security, health checks, and structure so juniors learn correct
> patterns from day one — not toy shortcuts.

---

## What makes this "production-grade" (even on a laptop)

| Concern | What we do | Where |
|---|---|---|
| **Non-root** | Pods run as uid/gid 101, drop ALL capabilities, no privilege escalation, RuntimeDefault seccomp | `lib/chutils` |
| **Auth** | `default` user password comes from a Kubernetes Secret, never Git; passwordless access is rejected | `lib/clickhouse`, `scripts/create-secret.sh` |
| **Health** | Startup + liveness + readiness probes on ClickHouse; operator-managed probes on Keeper | `lib/chutils` |
| **Pinned versions** | Operator `0.27.3`, images `25.8.29.51` (LTS) — no floating tags | env files, `chartfile.yaml` |
| **Network** | Default-deny ingress + explicit allow (operator, monitoring) | `lib/netpol` |
| **Scheduling** | PriorityClass; anti-affinity / topology-spread / PDB available as params | `lib/chutils`, `lib/*` |
| **Monitoring** | Prometheus endpoint on :9363 baked into the CHI | `lib/clickhouse` |
| **Reproducible** | Operator + charts managed by Tanka, pinned deps in `jsonnetfile.lock.json` | whole repo |

---

## Architecture

```
Developer → Tanka (Jsonnet) → Kubernetes manifests → Altinity Operator
                                                          ├── ClickHouse (CHI)
                                                          └── ClickHouse Keeper (CHK)
```

**CHI** (`ClickHouseInstallation`) and **CHK** (`ClickHouseKeeperInstallation`) are
Custom Resources. You declare intent; the operator reconciles StatefulSets, Services,
ConfigMaps, and PVCs. Without the operator running, applying a CHI/CHK does nothing.

---

## Repository Structure

```
clickhouse/
├── environments/
│   └── local/development/          # {cloud}/{tier} — matches org convention
│       ├── core/                   # namespace, PriorityClass, NetworkPolicies
│       ├── clickhouse-operator/    # operator via Helm (Tanka-managed) + chartfile.yaml
│       ├── clickhouse-keeper/      # CHK: params only
│       └── clickhouse/             # CHI: params only
│
├── lib/
│   ├── chutils/main.libsonnet      # pod template, PVC, VCT, securityContext, probes
│   ├── clickhouse/main.libsonnet   # new(params) → full hardened CHI (+ optional PDB)
│   ├── keeper/main.libsonnet       # new(params) → full hardened CHK (+ optional PDB)
│   ├── netpol/main.libsonnet       # default-deny + allow NetworkPolicies
│   ├── priority-class/priority.libsonnet
│   ├── k8sutils/podAntiAffinity.libsonnet
│   ├── clickhouse-operator-libsonnet/0.25/   # CRD builders (hand-vendored)
│   ├── clickhouse-keeper-libsonnet/0.25/     # CRD builders (hand-vendored)
│   └── k.libsonnet
│
├── scripts/create-secret.sh        # create the credentials Secret (password never in Git)
├── jsonnetfile.json / .lock.json   # jb dependencies (commit the lock)
├── Makefile
├── .gitignore
└── README.md
```

### Library design (why environments are tiny)

Each environment file only supplies **values**; the libraries own **structure and
security**. Adding a new environment (e.g. GKE prod) means one new params file — the
libs are untouched. This is the single most important pattern to learn here.

```jsonnet
// environments/local/development/clickhouse/main.jsonnet
local clickhouse = import 'clickhouse/main.libsonnet';
clickhouse.new({
  name: 'clickhouse', keeperHost: 'keeper-clickhouse-keeper',
  image: 'clickhouse/clickhouse-server:25.8.29.51',
  replicas: 1, storage: '20Gi', storageClass: 'standard',
  requests: {...}, limits: {...},
  passwordSecret: { name: 'clickhouse-credentials', key: 'password' },
})
```

---

## Prerequisites

```bash
kubectl version --client   # v1.35+
minikube version           # v1.38+   (running & current context)
helm version               # v4+
tk --version               # v0.38+   (Tanka)
jb --version               # v0.6+    (jsonnet-bundler)
docker version ; jq --version
```

---

## Quick Start

```bash
# 0. Vendor the operator Helm chart (once, or after changing chartfile.yaml)
make vendor-charts

# 1. Create the credentials Secret (generates a random password, prints it once)
make create-secret
#    or pin your own:  CLICKHOUSE_PASSWORD=... make create-secret

# 2. Apply everything in dependency order
make apply-core        # namespace + PriorityClass + NetworkPolicies
make apply-operator    # Altinity operator (Tanka-managed Helm)
make apply-keeper      # ClickHouse Keeper
make apply-clickhouse  # ClickHouse

# 3. Validate end-to-end (auth rejection, version, non-root, Keeper, replicated table)
make validate
```

`make vendor-and-apply-all` chains all of the above.

---

## Key Concepts for Juniors

### Dependency order matters
`core` (PriorityClass the pods reference) → `operator` (installs CRDs) →
`keeper` (ClickHouse coordinates through it) → `clickhouse`. Applying out of order
fails with clear errors — read them, don't guess.

### Operator/image version compatibility
Operator `0.27.3` injects the `use_xid_64` Keeper setting and an `http_control`
readiness endpoint — both require ClickHouse **25.x**. Pinning to an older LTS (24.8)
crash-loops Keeper with `UNKNOWN_SETTING`. **Lesson: match the image to the operator,
don't blindly pick "latest" or an old LTS.** We run `25.8.29.51`.

### The operator's resource naming
| Resource | Pattern | Example |
|---|---|---|
| ClickHouse pod | `chi-{chi}-{cluster}-{shard}-{replica}` | `chi-clickhouse-clickhouse-0-0-0` |
| Keeper pod | `chk-{chk}-{cluster}-{shard}-{replica}` | `chk-clickhouse-keeper-keeper-0-0-0` |
| Keeper service | `{cluster}-{chk}` | `keeper-clickhouse-keeper` |

The ClickHouse `zookeeperHost` must equal the Keeper service name.

### Why probes differ
ClickHouse exposes HTTP `/ping` → HTTP probes. Keeper has no HTTP `/ping`; the
operator renders its own `ruok`/`http_control` probes, so we do **not** define
container probes for Keeper (ours would override the operator's and break them).

---

## Makefile Reference

```
make show-<component>     preview YAML (core|operator|keeper|clickhouse)
make diff-<component>     diff against the live cluster
make apply-<component>    apply one component
make apply-all            apply all in order
make create-secret        create/rotate the credentials Secret
make vendor-charts        re-vendor the operator Helm chart

make status               CHI, CHK, pods, PVCs, services
make operator-status      Helm release + operator pod
make keeper-status        Keeper connection from inside ClickHouse
make validate             full end-to-end validation

make connect              interactive clickhouse-client (auth auto-pulled from Secret)
make query Q="SELECT 1"   run one query
make logs-ch|logs-keeper|logs-operator
```

The Makefile reads the password straight from the `clickhouse-credentials` Secret —
it is never written into any tracked file.

---

## Secrets

The `default` user password lives only in the `clickhouse-credentials` Kubernetes
Secret. `scripts/create-secret.sh` generates it (or takes `CLICKHOUSE_PASSWORD`).
The CHI references it via `valueFrom.secretKeyRef`, so the plaintext never enters
Jsonnet or Git. `.gitignore` blocks common secret filenames.

For a real cluster, graduate to Sealed Secrets, the External Secrets Operator, or
GCP Secret Manager via Workload Identity — do **not** hand-create Secrets in prod.

---

## Troubleshooting

```bash
kubectl get events -n clickhouse --sort-by='.lastTimestamp'   # first stop
kubectl describe chi clickhouse -n clickhouse                 # CHI status/message
make logs-operator                                            # reconcile errors
kubectl logs -n clickhouse <pod> --previous                   # crash logs
```

Common:
- **Keeper CrashLoop `UNKNOWN_SETTING`** → image too old for the operator; bump to 25.x.
- **`TABLE_IS_READ_ONLY`** → the table's Keeper metadata is gone (e.g. Keeper volume was
  reset). Drop and recreate the table.
- **`Authentication failed`** → expected without `--password`; the Makefile targets pass it.

---

## Git Hygiene

Commit: `lib/**`, `environments/**` (except charts), `jsonnetfile.lock.json`,
`Makefile`, `scripts/**`, `.gitignore`.
Never commit: passwords, Secrets, `kubeconfig`, `environments/**/charts/` (re-vendorable).
