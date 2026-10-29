#!/usr/bin/env bash
# Proves the NetworkPolicies work: tries each connection and checks it was
# ALLOWED or BLOCKED as intended. Results are saved as evidence for Task 3.
#
# Usage: ./scripts/test-network-policies.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
NS=devops-app
OUT=evidence/task3/network-policy-tests.txt
mkdir -p "$(dirname "$OUT")"
PASS=0; FAIL=0

# check "<description>" <ALLOWED|BLOCKED> <command...>
check() {
  local desc="$1" expected="$2"; shift 2
  local actual
  if "$@" >/dev/null 2>&1; then actual=ALLOWED; else actual=BLOCKED; fi
  if [ "$actual" = "$expected" ]; then result="PASS"; PASS=$((PASS+1)); else result="FAIL"; FAIL=$((FAIL+1)); fi
  printf '%-4s  %-58s expected %-7s got %s\n' "$result" "$desc" "$expected" "$actual" | tee -a "$OUT"
}

# TCP connect test from inside a pod, using whatever the image provides
py_connect() { kubectl exec -n $NS "$1" -- python -c "import socket; socket.create_connection(('$2', $3), 3)"; }
nc_connect() { kubectl exec -n "$4" "$1" -- nc -z -w 3 "$2" "$3"; }

FRONTEND=deploy/frontend
BACKEND=deploy/backend
WORKER=deploy/worker
POSTGRES=pod/postgres-0

# An "outsider" pod in a separate namespace with no policies of its own,
# so any block it hits comes from the devops-app policies.
# Remove leftovers from a previous run first (and wait until they're gone).
kubectl delete namespace np-test --ignore-not-found --wait=true >/dev/null
kubectl create namespace np-test >/dev/null
kubectl run outsider -n np-test --image=busybox:1.36 --restart=Never --command -- sleep 600 >/dev/null
# Without a running outsider pod, its "BLOCKED" results would be meaningless.
kubectl wait --for=condition=ready pod/outsider -n np-test --timeout=90s >/dev/null || {
  echo "ERROR: outsider test pod did not start - aborting"; exit 1; }

{
  echo "NetworkPolicy tests - $(date '+%Y-%m-%d %H:%M')"
  echo "Cluster: $(kubectl config current-context)   Namespace: $NS"
  echo
} > "$OUT"

echo "--- Entry point" | tee -a "$OUT"
check "internet -> frontend (through Ingress, localhost:8080)" ALLOWED curl -sf -m 5 http://localhost:8080/healthz
check "internet -> backend API (through nginx /api/health)"   ALLOWED curl -sf -m 5 http://localhost:8080/api/health

echo "--- Pods outside the app may not reach anything" | tee -a "$OUT"
check "control: outsider pod is alive and can reach cluster DNS" ALLOWED kubectl exec -n np-test outsider -- nslookup kubernetes.default.svc.cluster.local
check "outsider pod -> frontend:8080 (direct, bypassing Ingress)" BLOCKED nc_connect outsider frontend.$NS.svc.cluster.local 80 np-test
check "outsider pod -> backend:8000"                               BLOCKED nc_connect outsider backend.$NS.svc.cluster.local 8000 np-test
check "outsider pod -> postgres:5432"                              BLOCKED nc_connect outsider postgres.$NS.svc.cluster.local 5432 np-test

echo "--- Allowed internal paths" | tee -a "$OUT"
check "frontend -> backend:8000"  ALLOWED kubectl exec -n $NS $FRONTEND -- wget -q -T 3 -O /dev/null http://backend:8000/healthz
check "backend  -> postgres:5432" ALLOWED py_connect $BACKEND postgres 5432
check "worker   -> postgres:5432" ALLOWED py_connect $WORKER postgres 5432

echo "--- Blocked internal paths" | tee -a "$OUT"
check "frontend -> postgres:5432 (frontend never needs the DB)" BLOCKED nc_connect $FRONTEND postgres 5432 $NS
check "worker   -> backend:8000"                                 BLOCKED py_connect $WORKER backend 8000
check "backend  -> worker (worker accepts no connections)"       BLOCKED py_connect $BACKEND "$(kubectl get pod -n $NS -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].status.podIP}')" 8000

echo "--- Outbound (egress)" | tee -a "$OUT"
check "backend  -> AWS API over HTTPS (sts.amazonaws.com:443)" ALLOWED py_connect $BACKEND sts.amazonaws.com 443
check "backend  -> internet over plain HTTP (port 80)"          BLOCKED py_connect $BACKEND example.com 80
check "postgres -> internet (database makes no outbound calls)" BLOCKED nc_connect $POSTGRES 1.1.1.1 443 $NS

kubectl delete namespace np-test --wait=false >/dev/null

echo | tee -a "$OUT"
echo "Result: $PASS passed, $FAIL failed   (saved to $OUT)" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
