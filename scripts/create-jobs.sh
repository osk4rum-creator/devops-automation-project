#!/usr/bin/env bash
# Creates / updates the two pipeline jobs from code.
#
# The jobs are defined with Job DSL inside the JCasC config in
# jenkins/values.yaml. This script tells Jenkins to re-apply that config
# (idempotent: existing jobs are updated, never duplicated) and checks that
# both jobs exist afterwards.
#
# Usage: ./scripts/create-jobs.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source scripts/jenkins-api.sh

echo "==> Reloading Jenkins Configuration as Code (includes the Job DSL job definitions)"
jenkins_api POST /configuration-as-code/reload > /dev/null   # shell redirect: works on Windows too

for i in $(seq 1 20); do
  jobs="$(jenkins_api GET '/api/json?tree=jobs[name]' || true)"
  if echo "$jobs" | grep -q '"application-ci"' && echo "$jobs" | grep -q '"application-cd"'; then
    echo "==> Jobs present: application-ci, application-cd"
    exit 0
  fi
  sleep 3
done
echo "ERROR: jobs not found after reload. Check: kubectl logs statefulset/jenkins -n jenkins -c jenkins"
exit 1
