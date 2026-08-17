local k = import 'k.libsonnet';
local priority = import 'priority-class/priority.libsonnet';
local netpol = import 'netpol/main.libsonnet';

{
  namespace: k.core.v1.namespace.new('clickhouse'),

  // High priority class ensures ClickHouse/Keeper pods are scheduled preferentially
  // and are the last to be evicted under node pressure.
  priorityClass: priority.new(
    className='high-priority',
    classValue=1000,
    description='High priority for database workloads (ClickHouse, Keeper)',
  ).priorityClass,

  // Default-deny + explicit-allow network policies. Not enforced by Minikube's
  // default CNI, but applied here so dev mirrors prod. Enforced on GKE.
  networkPolicies: netpol.new(),
}
