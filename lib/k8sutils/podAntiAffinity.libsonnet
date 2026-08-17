local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';

local statefulSet = k.apps.v1.statefulSet,
      podAntiAffinity = statefulSet.spec.template.spec.affinity.podAntiAffinity;

{
  onLabels(key, value, topologyKey='kubernetes.io/hostname'):: {
    labelSelector: {
      matchExpressions: [
        {
          key: key,
          operator: 'In',
          values: [value],
        },
      ],
    },
    topologyKey: topologyKey,
  },
}
