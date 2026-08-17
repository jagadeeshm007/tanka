local keeper = import 'keeper/main.libsonnet';

// Minikube: single Keeper replica, minimal resources, local hostpath storage.
keeper.new({
  image: 'clickhouse/clickhouse-keeper:25.8.29.51',
  replicas: 1,
  storage: '5Gi',
  storageClass: 'standard',
  requests: { cpu: '100m', memory: '256Mi' },
  limits: { cpu: '500m', memory: '1Gi' },
})
