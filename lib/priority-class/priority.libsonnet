local k = import 'github.com/grafana/jsonnet-libs/ksonnet-util/kausal.libsonnet';
local pc = k.scheduling.v1.priorityClass;

/*  for more info
    refer https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
*/
{
  new(className, classValue, description, preemptionPolicy='PreemptLowerPriority'):: {
    local base = self,

    priorityClass: pc.new(
                     className,
                   )
                   + pc.withValue(classValue)
                   + pc.withDescription(description)
                   + pc.withPreemptionPolicy(preemptionPolicy),
  },
}
