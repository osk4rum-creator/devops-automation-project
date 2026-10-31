#!/usr/bin/env bash
# Removes Jenkins completely: release, RBAC, credentials and Jenkins home (PVC).
# The app in devops-app keeps running.
#
# Usage: ./scripts/uninstall-jenkins.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

helm uninstall jenkins -n jenkins --ignore-not-found
kubectl delete -f jenkins/rbac.yaml --ignore-not-found
kubectl delete namespace jenkins --ignore-not-found --wait=true   # also deletes the PVC and secrets
echo "==> Jenkins removed"
