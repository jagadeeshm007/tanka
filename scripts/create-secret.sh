#!/usr/bin/env bash
# create-secret.sh — create the ClickHouse default-user credentials Secret.
#
# The password is never stored in Git. This script generates one (or accepts
# CLICKHOUSE_PASSWORD from the environment) and creates a Kubernetes Secret that
# the ClickHouseInstallation references via valueFrom.secretKeyRef.
#
# Usage:
#   ./scripts/create-secret.sh [namespace] [context]
#   CLICKHOUSE_PASSWORD=mypass ./scripts/create-secret.sh clickhouse minikube
#
# For production, prefer an external secret manager (Sealed Secrets / External
# Secrets Operator / GCP Secret Manager via Workload Identity) instead of this.

set -euo pipefail

NAMESPACE="${1:-clickhouse}"
CONTEXT="${2:-$(kubectl config current-context)}"
SECRET_NAME="clickhouse-credentials"

PASSWORD="${CLICKHOUSE_PASSWORD:-$(openssl rand -base64 24)}"

echo "Creating Secret '${SECRET_NAME}' in namespace '${NAMESPACE}' (context: ${CONTEXT})"

kubectl --context "${CONTEXT}" create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -

kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
  create secret generic "${SECRET_NAME}" \
  --from-literal=password="${PASSWORD}" \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -

echo "Done. Password stored only in the Secret (not in Git)."
if [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
  echo "Generated password: ${PASSWORD}"
  echo "Save it in your password manager — it is not recoverable from Git."
fi
