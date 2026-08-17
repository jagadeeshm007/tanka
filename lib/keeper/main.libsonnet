// keeper/main.libsonnet — build a hardened ClickHouseKeeperInstallation from params.
//
// The Keeper CRD (clickhouse-keeper.altinity.com/v1) has no public jsonnet-libs
// generator, so we build the object directly — it is a small, stable structure.
// Operator 0.27.x renders Keeper's own health probes (ruok liveness, http_control
// /ready readiness on :9182), so we do NOT define container probes here.
//
//   local keeper = import 'keeper/main.libsonnet';
//   keeper.new({ replicas: 3, ... })

local chutils = import 'chutils/main.libsonnet';
local k = import 'k.libsonnet';
local pdb = k.policy.v1.podDisruptionBudget;
local podAntiAffinityUtil = import 'k8sutils/podAntiAffinity.libsonnet';

{
  defaults:: {
    name: 'clickhouse-keeper',
    namespace: 'clickhouse',
    // Cluster name must be <= 15 bytes (CRD constraint).
    cluster: 'keeper',
    replicas: 1,
    storage: '5Gi',
    storageClass: 'standard',
    requests: { cpu: '100m', memory: '256Mi' },
    limits: { cpu: '500m', memory: '1Gi' },
    enableAntiAffinity: false,
    topologyKey: 'kubernetes.io/hostname',
  },

  new(params):: (
    local p = $.defaults + params;
    local sc = chutils.securityContext;

    local antiAffinity =
      if p.enableAntiAffinity then {
        affinity: {
          podAntiAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: [
              podAntiAffinityUtil.onLabels(
                'clickhouse-keeper.altinity.com/cluster', p.cluster, p.topologyKey,
              ),
            ],
          },
        },
      } else {};

    local keeperObject = {
      apiVersion: 'clickhouse-keeper.altinity.com/v1',
      kind: 'ClickHouseKeeperInstallation',
      metadata: {
        name: p.name,
        namespace: p.namespace,
        annotations: { 'argocd.argoproj.io/compare-options': 'IgnoreExtraneous' },
      },
      spec: {
        defaults: {
          templates: {
            podTemplate: 'keeper-pod',
            dataVolumeClaimTemplate: 'default',
          },
        },
        configuration: {
          clusters: [{
            name: p.cluster,
            layout: { replicasCount: p.replicas },
          }],
          settings: { 'logger/level': 'information' },
        },
        templates: {
          podTemplates: [{
            name: 'keeper-pod',
            spec: {
              securityContext: sc.pod,
              containers: [{
                name: 'clickhouse-keeper',
                image: p.image,
                imagePullPolicy: 'IfNotPresent',
                securityContext: sc.container,
                resources: { requests: p.requests, limits: p.limits },
              }],
            } + antiAffinity,
          }],
          volumeClaimTemplates: [{
            name: 'default',
            spec: {
              accessModes: ['ReadWriteOnce'],
              storageClassName: p.storageClass,
              resources: { requests: { storage: p.storage } },
            },
          }],
        },
      },
    };

    // Optional PDB: Keeper needs a majority quorum to stay writable, so guard with
    // minAvailable in HA setups (e.g. 2 of 3).
    local disruptionBudget =
      if std.objectHas(params, 'minAvailable') then {
        pdb:
          pdb.new(p.name + '-pdb')
          + pdb.metadata.withNamespace(p.namespace)
          + pdb.spec.withMinAvailable(params.minAvailable)
          + pdb.spec.selector.withMatchLabels({ 'clickhouse-keeper.altinity.com/chk': p.name }),
      } else {};

    { keeper: keeperObject } + disruptionBudget
  ),
}
