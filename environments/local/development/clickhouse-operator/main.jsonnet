local tanka = import 'github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet';
local k = import 'k.libsonnet';
local helm = tanka.helm.new(std.thisFile);

{
  // The operator owns its own namespace (separate lifecycle from workloads).
  namespace: k.core.v1.namespace.new('clickhouse-operator'),

  clickhouse_operator: helm.template('clickhouse-operator', './charts/altinity-clickhouse-operator', {
    namespace: 'clickhouse-operator',
    values: {
      // Watch only the clickhouse namespace — principle of least privilege
      watchNamespaces: ['clickhouse'],
      // CRD hook uses bitnami/kubectl:latest which can hit rate limits.
      // Disable it; CRDs are applied via includeCrds below.
      // On production with ArgoCD, applyStrategy=server handles large CRD annotations.
      crdHook: { enabled: false },
    },
    includeCrds: true,
  }),
}
