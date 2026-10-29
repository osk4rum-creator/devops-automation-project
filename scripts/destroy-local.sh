#!/usr/bin/env bash
# Removes the app from the cluster, and optionally the whole local cluster.
#
# Usage: ./scripts/destroy-local.sh            remove the app + namespace (keeps the cluster)
#        ./scripts/destroy-local.sh --cluster  also delete the k3d cluster itself
set -euo pipefail

CLUSTER="${CLUSTER_NAME:-devops}"
NAMESPACE="devops-app"

echo "==> Uninstalling Helm release"
helm uninstall devops-app -n "$NAMESPACE" --ignore-not-found

# Deleting the namespace also removes the Secrets and the database volume (PVC)
echo "==> Deleting namespace $NAMESPACE (secrets and database data included)"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true

if [ "${1:-}" = "--cluster" ]; then
  echo "==> Deleting k3d cluster $CLUSTER"
  k3d cluster delete "$CLUSTER"
fi

echo "==> Done. Local secret files in secrets/ are kept (gitignored); delete them manually if wanted."
