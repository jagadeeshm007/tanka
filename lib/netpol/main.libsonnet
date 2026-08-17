// netpol/main.libsonnet — default-deny + explicit-allow NetworkPolicies for the
// ClickHouse namespace.
//
// NOTE: NetworkPolicy is only enforced by a CNI that supports it (GKE Dataplane V2 /
// Cilium / Calico). Minikube's default bridge CNI does not enforce it — the objects
// still apply cleanly and become effective on GKE.
//
//   local netpol = import 'netpol/main.libsonnet';
//   netpol.new({ operatorNamespace: 'clickhouse-operator', monitoringNamespace: 'monitoring' })

local k = import 'k.libsonnet';
local np = k.networking.v1.networkPolicy;

local nsSelector(name) = { namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': name } } };

{
  defaults:: {
    operatorNamespace: 'clickhouse-operator',
    monitoringNamespace: 'monitoring',
  },

  new(params={}):: (
    local p = $.defaults + params;
    {
      // 1. Default-deny all ingress in the namespace.
      defaultDenyIngress:
        np.new('default-deny-ingress')
        + np.spec.withPolicyTypes(['Ingress'])
        + np.spec.podSelector.withMatchLabels({}),

      // 2. Allow ClickHouse/Keeper traffic from within the namespace (replication,
      //    inter-node) and from the operator namespace (reconcile/health).
      allowInternalAndOperator:
        np.new('allow-internal-and-operator')
        + np.spec.withPolicyTypes(['Ingress'])
        + np.spec.podSelector.withMatchLabels({})
        + np.spec.withIngress([{
          from: [
            { podSelector: {} },
            nsSelector(p.operatorNamespace),
          ],
          ports: [
            { protocol: 'TCP', port: 8123 },  // HTTP
            { protocol: 'TCP', port: 9000 },  // native
            { protocol: 'TCP', port: 9009 },  // interserver replication
            { protocol: 'TCP', port: 2181 },  // keeper client
            { protocol: 'TCP', port: 9444 },  // keeper raft
            { protocol: 'TCP', port: 9182 },  // keeper http_control
          ],
        }]),

      // 3. Allow Prometheus scraping of the metrics port from the monitoring namespace.
      allowMonitoring:
        np.new('allow-monitoring')
        + np.spec.withPolicyTypes(['Ingress'])
        + np.spec.podSelector.withMatchLabels({})
        + np.spec.withIngress([{
          from: [nsSelector(p.monitoringNamespace)],
          ports: [{ protocol: 'TCP', port: 9363 }],
        }]),
    }
  ),
}
