local clickhouse = import 'clickhouse/main.libsonnet';

// Minikube (2-node): 2 replicas with anti-affinity so each lands on a different node.
// The default-user password is sourced from the 'clickhouse-credentials' Secret
// (see environments/.../clickhouse/secret — created out-of-band, never committed).
clickhouse.new({
  name: 'clickhouse',
  cluster: 'clickhouse',
  keeperHost: 'keeper-clickhouse-keeper',
  image: 'clickhouse/clickhouse-server:25.8.29.51',
  replicas: 2,
  storage: '20Gi',
  storageClass: 'standard',
  requests: { cpu: '500m', memory: '1Gi' },
  limits: { cpu: '2', memory: '4Gi' },
  enableAntiAffinity: true,
  passwordSecret: { name: 'clickhouse-credentials', key: 'password' },
})
