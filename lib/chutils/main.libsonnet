// chutils/main.libsonnet — ClickHouse pod template, PVC, and volume-claim-template factories.
//
// Redesigned around options objects (instead of long positional arg lists) so that
// probes, securityContext, and scheduling constraints are explicit and composable.
// Used by lib/clickhouse and lib/keeper to build hardened, production-ready pods.

local chi = (import 'github.com/jsonnet-libs/clickhouse-operator-libsonnet/0.25/main.libsonnet').clickhouse.v1.clickHouseInstallation;
local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';
local podAntiAffinityUtil = import 'k8sutils/podAntiAffinity.libsonnet';

local podTemplate = k.core.v1.podTemplate,
      pvc = k.core.v1.persistentVolumeClaim,
      pvcTemplate = k.core.v1.persistentVolumeClaimTemplate,
      volumeMount = k.core.v1.volumeMount,
      container = k.core.v1.container;

local pt = chi.spec.templates.podTemplates;
local vct = chi.spec.templates.volumeClaimTemplates;

{
  // ── Security baseline ───────────────────────────────────────────────────────
  // ClickHouse images ship a `clickhouse` user at uid/gid 101. Running as that
  // non-root user, dropping all Linux capabilities, blocking privilege escalation
  // and applying the runtime default seccomp profile is the CIS-aligned baseline.
  // Kept as a public field so callers can inspect or override it.
  //
  // NOTE on non-root placement: runAsNonRoot/runAsUser live on the *container*, not
  // the pod. This keeps the long-running server guaranteed non-root while still
  // allowing a one-shot root initContainer to fix volume ownership (a pod-level
  // runAsNonRoot:true would forbid that init container). fsGroup stays at pod level.
  securityContext:: {
    pod: {
      fsGroup: 101,
      fsGroupChangePolicy: 'OnRootMismatch',
      seccompProfile: { type: 'RuntimeDefault' },
    },
    // Applied to the main clickhouse-server container — the process that matters.
    container: {
      runAsNonRoot: true,
      runAsUser: 101,
      runAsGroup: 101,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
      // readOnlyRootFilesystem intentionally left false: the operator regenerates
      // config under /etc/clickhouse-server and the server writes format schemas
      // outside the data volume. Revisit with explicit emptyDir mounts if required.
    },
  },

  // Root, one-shot init container that makes the data volume writable by uid 101.
  // Needed because Minikube's hostpath provisioner does not reliably honor fsGroup;
  // on cloud storage classes that do honor it this is a harmless no-op.
  volumePermissionsInit(dataVolume='data'):: {
    name: 'volume-permissions',
    image: 'busybox:1.36',
    command: ['sh', '-c', 'chown -R 101:101 /var/lib/clickhouse'],
    securityContext: {
      runAsUser: 0,
      runAsNonRoot: false,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'], add: ['CHOWN'] },
    },
    volumeMounts: [{ name: dataVolume, mountPath: '/var/lib/clickhouse' }],
  },

  // ── Probes ──────────────────────────────────────────────────────────────────
  // startup: gives a cold/replicating node up to 30 min before liveness engages.
  // liveness: restarts a hung server. readiness: pulls a non-serving pod from the
  // Service (e.g. during heavy merges or replication catch-up) without a restart.
  probes(port='http'):: {
    startupProbe: {
      httpGet: { path: '/ping', port: port },
      periodSeconds: 10,
      failureThreshold: 180,  // 180 × 10s = 30 min
    },
    livenessProbe: {
      httpGet: { path: '/ping', port: port },
      periodSeconds: 30,
      timeoutSeconds: 5,
      failureThreshold: 3,
    },
    readinessProbe: {
      httpGet: { path: '/ping', port: port },
      periodSeconds: 10,
      timeoutSeconds: 3,
      failureThreshold: 3,
      successThreshold: 1,
    },
  },

  // ── PVC (standalone) ─────────────────────────────────────────────────────────
  // Use when you want a disk whose lifecycle is decoupled from the CHI. For
  // replicated clusters prefer DataVolumeClaimTemplate (operator-managed, one
  // PVC per replica, scales with replicasCount).
  CreatePVC(name, storageClass, size)::
    pvc.new(name)
    + pvc.spec.withAccessModes(['ReadWriteOnce'])
    + pvc.spec.withStorageClassName(storageClass)
    + pvc.spec.resources.withRequests({ storage: size }),

  // ── VolumeClaimTemplate (operator-managed) ────────────────────────────────────
  // The operator provisions one PVC per replica from this template. Pair with a
  // StorageClass whose reclaimPolicy is Retain in production for data durability.
  DataVolumeClaimTemplate(name, storageClass, size)::
    vct.withName(name)
    + vct.withSpec({
      accessModes: ['ReadWriteOnce'],
      storageClassName: storageClass,
      resources: { requests: { storage: size } },
    }),

  // ── PodTemplate ───────────────────────────────────────────────────────────────
  // params:
  //   name           template name (referenced by defaults.templates.podTemplate)
  //   image          fully-pinned image ref (repo:MAJOR.MINOR.PATCH.BUILD)
  //   cluster        cluster label value, used for pod anti-affinity
  //   requests/limits resource maps
  //   priorityClass  optional PriorityClass name
  //   enableAntiAffinity  spread replicas across nodes (true in prod)
  //   topologyKey    anti-affinity topology (host by default; zone in prod)
  //   dataVolume     name of the volumeMount/volume backing /var/lib/clickhouse
  PodTemplate(params):: (
    local sc = $.securityContext;
    local antiAffinity =
      if std.get(params, 'enableAntiAffinity', false) then {
        affinity: {
          podAntiAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: [
              podAntiAffinityUtil.onLabels(
                'clickhouse.altinity.com/cluster',
                params.cluster,
                std.get(params, 'topologyKey', 'kubernetes.io/hostname'),
              ),
            ],
          },
        },
      } else {};

    local ctr =
      container.new('clickhouse-server', params.image)
      + container.withImagePullPolicy('IfNotPresent')
      + container.withVolumeMounts([volumeMount.new(std.get(params, 'dataVolume', 'data'), '/var/lib/clickhouse')])
      + container.resources.withRequests(params.requests)
      + container.resources.withLimits(params.limits)
      + { securityContext: sc.container }
      + $.probes('http');

    local spec =
      {
        initContainers: [$.volumePermissionsInit(std.get(params, 'dataVolume', 'data'))],
        containers: [ctr],
        securityContext: sc.pod,
      }
      + antiAffinity
      + (if std.objectHas(params, 'priorityClass') then { priorityClassName: params.priorityClass } else {})
      + (if std.get(params, 'topologySpread', false) then {
           topologySpreadConstraints: [{
             maxSkew: 1,
             topologyKey: 'topology.kubernetes.io/zone',
             whenUnsatisfiable: 'ScheduleAnyway',
             labelSelector: { matchLabels: { 'clickhouse.altinity.com/cluster': params.cluster } },
           }],
         } else {});

    pt.withName(params.name) + pt.withSpec(spec)
  ),
}
