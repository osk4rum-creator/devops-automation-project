#!/usr/bin/env bash
# Applies changes from jenkins/values.yaml (plugins, JCasC, agent templates)
# to the running Jenkins. JCasC changes are picked up by the chart's
# config-reload sidecar; plugin changes restart the controller.
#
# Usage: ./scripts/configure-jenkins.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

kubectl apply -f jenkins/rbac.yaml
kubectl apply -f jenkins/networkpolicy.yaml   # who may connect to the controller
helm upgrade jenkins jenkins/jenkins \
  --version 5.10.2 \
  --namespace jenkins \
  -f jenkins/values.yaml \
  --wait --timeout 15m

kubectl rollout status statefulset/jenkins -n jenkins --timeout=10m
echo "==> Configuration applied. Run ./scripts/create-jobs.sh to (re)load jobs."
