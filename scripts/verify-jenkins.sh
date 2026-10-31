#!/usr/bin/env bash
# Checks the Jenkins installation and saves the outputs Task 4 asks for.
#
# Usage: ./scripts/verify-jenkins.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source scripts/jenkins-api.sh

OUT=evidence/task4/01-jenkins-install.txt
mkdir -p "$(dirname "$OUT")"
FAIL=0

run() { { echo "\$ $*"; "$@" 2>&1; echo; } | tee -a "$OUT"; }
ok()  { echo "PASS  $1" | tee -a "$OUT"; }
bad() { echo "FAIL  $1" | tee -a "$OUT"; FAIL=1; }

echo "# Jenkins installation - collected $(date '+%Y-%m-%d %H:%M')" > "$OUT"; echo >> "$OUT"

run kubectl get namespaces
run kubectl get pods -n jenkins -o wide
run kubectl get service,ingress,pvc -n jenkins
run kubectl get serviceaccount,role,rolebinding -n jenkins
run kubectl get role,rolebinding -n devops-app
run helm list -n jenkins

echo "--- checks" | tee -a "$OUT"
[ "$(kubectl get pod jenkins-0 -n jenkins -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}')" = "true" ] \
  && ok "controller pod is Ready" || bad "controller pod is not Ready"

[ "$(kubectl get pvc jenkins -n jenkins -o jsonpath='{.status.phase}')" = "Bound" ] \
  && ok "Jenkins home PVC is Bound" || bad "Jenkins home PVC not bound"

curl -sf "$JENKINS_URL/login" > /dev/null && ok "UI reachable at $JENKINS_URL" || bad "UI not reachable at $JENKINS_URL"

executors="$(jenkins_api GET '/computer/api/json?tree=computer[displayName,numExecutors]' || echo '')"
echo "$executors" | grep -q '"numExecutors":0' && ok "controller has 0 executors (never runs builds)" || bad "controller executors not 0"

jobs="$(jenkins_api GET '/api/json?tree=jobs[name]' || echo '')"
for j in application-ci application-cd; do
  echo "$jobs" | grep -q "\"$j\"" && ok "job $j exists (created by Job DSL)" || bad "job $j missing"
done

# RBAC: CI may do nothing, the deployer only inside devops-app
[ "$(kubectl auth can-i create deployments -n devops-app --as=system:serviceaccount:jenkins:jenkins-agent-ci)" = "no" ] \
  && ok "CI agent can NOT deploy" || bad "CI agent can deploy"
[ "$(kubectl auth can-i patch deployments -n devops-app --as=system:serviceaccount:jenkins:jenkins-deployer)" = "yes" ] \
  && ok "deployer CAN update deployments in devops-app" || bad "deployer cannot deploy"
[ "$(kubectl auth can-i patch deployments -n kube-system --as=system:serviceaccount:jenkins:jenkins-deployer)" = "no" ] \
  && ok "deployer can NOT touch other namespaces (kube-system)" || bad "deployer has access outside devops-app"
[ "$(kubectl auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:jenkins:jenkins-deployer)" = "no" ] \
  && ok "deployer is NOT cluster-admin" || bad "deployer is cluster-admin"

echo | tee -a "$OUT"
[ $FAIL -eq 0 ] && echo "All checks passed (saved to $OUT)" || echo "Some checks FAILED (saved to $OUT)"
exit $FAIL
