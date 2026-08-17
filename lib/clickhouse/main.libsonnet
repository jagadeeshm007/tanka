// clickhouse/main.libsonnet — build a complete, hardened ClickHouseInstallation from params.
//
// One code path for every environment (minikube / dev / prod). Environments supply
// only values; this library owns the structure, security, probes, and monitoring wiring.
//
//   local clickhouse = import 'clickhouse/main.libsonnet';
//   clickhouse.new({ name: 'clickhouse', replicas: 3, ... })

local chutils = import 'chutils/main.libsonnet';
local chi = (import 'github.com/jsonnet-libs/clickhouse-operator-libsonnet/0.25/main.libsonnet').clickhouse.v1.clickHouseInstallation;
local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';

local chiCluster = chi.spec.configuration.clusters;
local service = k.core.v1.service;
local pdb = k.policy.v1.podDisruptionBudget;

// Prometheus scrape endpoint served on :9363 (referenced by the metrics port).
local prometheusXml =
  '<clickhouse><prometheus>' +
  '<endpoint>/metrics</endpoint><port>9363</port>' +
  '<metrics>true</metrics><events>true</events><errors>true</errors>' +
  '<asynchronous_metrics>true</asynchronous_metrics>' +
  '</prometheus></clickhouse>';

{
  // Defaults keep environment files terse; each is overridable per environment.
  defaults:: {
    namespace: 'clickhouse',
    cluster: 'clickhouse',
    replicas: 1,
    priorityClass: 'high-priority',
    enableAntiAffinity: false,
    topologySpread: false,
    topologyKey: 'kubernetes.io/hostname',
    // Source network allowed to authenticate. Pod/cluster CIDR by default.
    // Replication over the interserver port (9009) is unaffected by this.
    networks: '10.0.0.0/8',
    extraSettings: {},
    extraProfiles: {},
  },

  new(params):: (
    local p = $.defaults + params;
    local podName = p.name + '-pod';

    // Users: the default account authenticates with a password sourced from a
    // Kubernetes Secret (never committed). `host_regexp: .*` is deliberately
    // omitted — a password plus a bounded source network is the baseline.
    local users =
      {
        'default/profile': 'default',
        'default/quota': 'default',
        'default/networks/ip': p.networks,
      }
      + (
        if std.objectHas(p, 'passwordSecret') then {
          'default/password': {
            valueFrom: {
              secretKeyRef: {
                name: p.passwordSecret.name,
                key: p.passwordSecret.key,
              },
            },
          },
        } else { 'default/password': '' }
      );

    // Explicit ClusterIP service exposing HTTP, native, and metrics ports.
    local svc =
      service.newWithoutSelector('ch-cluster-svc')
      + service.spec.withType('ClusterIP')
      + service.spec.withPorts([
        { name: 'http', port: 8123 },
        { name: 'tcp', port: 9000 },
        { name: 'metrics', port: 9363 },
      ]);
    local svcTemplate =
      chi.spec.templates.serviceTemplates.withName('ch-cluster-svc')
      + chi.spec.templates.serviceTemplates.withSpec(svc.spec)
      + chi.spec.templates.serviceTemplates.withMetadata(svc.metadata);

    local podTmpl = chutils.PodTemplate({
      name: podName,
      image: p.image,
      cluster: p.cluster,
      requests: p.requests,
      limits: p.limits,
      priorityClass: p.priorityClass,
      enableAntiAffinity: p.enableAntiAffinity,
      topologyKey: p.topologyKey,
      topologySpread: p.topologySpread,
    });

    local chiObject =
      chi.new(p.name)
      + chi.metadata.withNamespace(p.namespace)
      + chi.metadata.withAnnotationsMixin({ 'argocd.argoproj.io/compare-options': 'IgnoreExtraneous' })
      // Wire every replica to the shared pod + data templates.
      + chi.spec.defaults.templates.withPodTemplate(podName)
      + chi.spec.defaults.templates.withDataVolumeClaimTemplate('data')
      + chi.spec.defaults.templates.withServiceTemplate('ch-cluster-svc')
      + chi.spec.templates.withPodTemplates([podTmpl])
      + chi.spec.templates.withVolumeClaimTemplates([
        chutils.DataVolumeClaimTemplate('data', p.storageClass, p.storage),
      ])
      + chi.spec.templates.withServiceTemplates([svcTemplate])
      + chi.spec.configuration.zookeeper.withNodes([{ host: p.keeperHost, port: 2181 }])
      // 1 shard × N replicas — HA, not sharding.
      + chi.spec.configuration.withClusters([
        chiCluster.withName(p.cluster)
        + chiCluster.layout.withReplicasCount(p.replicas),
      ])
      + chi.spec.configuration.withSettings({
        disable_internal_dns_cache: 1,
        max_concurrent_queries: 1000,
      } + p.extraSettings)
      + chi.spec.configuration.withProfiles(p.extraProfiles)
      + chi.spec.configuration.withFiles({ 'config.d/prometheus.xml': prometheusXml })
      + chi.spec.configuration.withUsers(users);

    // Optional PodDisruptionBudget: keeps replicas available during voluntary
    // disruptions (node drains/upgrades). Enable in prod via params.maxUnavailable.
    local disruptionBudget =
      if std.objectHas(params, 'maxUnavailable') then {
        pdb:
          pdb.new(p.name + '-pdb')
          + pdb.metadata.withNamespace(p.namespace)
          + pdb.spec.withMaxUnavailable(params.maxUnavailable)
          + pdb.spec.selector.withMatchLabels({ 'clickhouse.altinity.com/chi': p.name }),
      } else {};

    { clickhouse: chiObject } + disruptionBudget
  ),
}
