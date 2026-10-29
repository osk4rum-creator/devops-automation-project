#!/usr/bin/env bash
# Collects every output Task 3 asks for into evidence/task3/, so the whole
# evidence folder can be regenerated with one command.
#
# Usage: ./scripts/collect-evidence.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
NS=devops-app
OUT=evidence/task3
mkdir -p "$OUT"

# run <file> <command...>: prints "$ command" and its output into the file
run() {
  local file="$OUT/$1"; shift
  { echo "\$ $*"; "$@" 2>&1; echo; } >> "$file"
}
start() { echo "# $2 - collected $(date '+%Y-%m-%d %H:%M')" > "$OUT/$1"; echo >> "$OUT/$1"; echo "  -> $OUT/$1"; }

pod_of() { kubectl get pod -n $NS -l "app.kubernetes.io/name=$1" -o jsonpath='{.items[0].metadata.name}'; }
psql_q() { kubectl exec -n $NS postgres-0 -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"$1\""; }

echo "Collecting Task 3 evidence (context: $(kubectl config current-context))"

# --- 1. The commands listed in the task PDF -----------------------------------
start 01-cluster-and-workloads.txt "Cluster, namespace and workloads"
run 01-cluster-and-workloads.txt kubectl get nodes -o wide
run 01-cluster-and-workloads.txt kubectl get namespaces
run 01-cluster-and-workloads.txt kubectl get pods -n $NS -o wide
run 01-cluster-and-workloads.txt kubectl get deployments,statefulsets -n $NS
run 01-cluster-and-workloads.txt kubectl get services -n $NS
run 01-cluster-and-workloads.txt kubectl get ingress -n $NS
run 01-cluster-and-workloads.txt kubectl get configmaps,secrets,serviceaccounts,pvc,networkpolicies -n $NS
run 01-cluster-and-workloads.txt helm list -n $NS

start 02-describe-pods.txt "kubectl describe for each component"
for c in frontend backend worker postgres; do
  run 02-describe-pods.txt kubectl describe pod "$(pod_of $c)" -n $NS
done

start 03-logs.txt "Recent logs of each component"
for c in frontend backend worker postgres; do
  run 03-logs.txt kubectl logs "$(pod_of $c)" -n $NS --tail=25
done

# --- 2. The app works end to end -------------------------------------------------
start 04-app-tests.txt "Application tests"
NOTE="evidence note $(date '+%H:%M:%S')"
run 04-app-tests.txt curl -s -o /dev/null -w "HTTP %{http_code} from the web page through the Ingress\n" http://localhost:8080/
run 04-app-tests.txt curl -s http://localhost:8080/api/health
echo "## frontend -> backend (from inside a frontend pod)" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt kubectl exec -n $NS deploy/frontend -- wget -qO- http://backend:8000/healthz
echo "## write to the database through the API" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt curl -s -X POST -H "Content-Type: application/json" -d "{\"text\":\"$NOTE\"}" http://localhost:8080/api/notes
echo "## read it back through the API" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt curl -s http://localhost:8080/api/notes
echo "## confirm it is stored in PostgreSQL" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt psql_q "SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT 3;"
echo "## worker picks up a new upload row (SNS disabled: AWS account blocked, see README)" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt psql_q "INSERT INTO uploads (filename, s3_key) VALUES ('evidence.txt', 'uploads/evidence.txt');"
sleep 15
run 04-app-tests.txt kubectl logs deploy/worker -n $NS --tail=3
run 04-app-tests.txt psql_q "SELECT id, filename, notified FROM uploads ORDER BY id DESC LIMIT 3;"
echo "## S3 upload while AWS credentials are absent -> clear error, no crash" >> "$OUT/04-app-tests.txt"
echo "evidence" > "$OUT/.upload-test.txt"
run 04-app-tests.txt curl -s -F "file=@$OUT/.upload-test.txt" http://localhost:8080/api/upload
rm -f "$OUT/.upload-test.txt"

# --- 3. Self-healing: delete pods, the system keeps working ---------------------------
start 05-self-healing.txt "Pod restart tests"
echo "## backend pods before" >> "$OUT/05-self-healing.txt"
run 05-self-healing.txt kubectl get pods -n $NS -l app.kubernetes.io/name=backend
run 05-self-healing.txt kubectl delete pod -n $NS -l app.kubernetes.io/name=backend
run 05-self-healing.txt kubectl rollout status deployment/backend -n $NS --timeout=120s
echo "## backend pods after (new names, AGE of seconds)" >> "$OUT/05-self-healing.txt"
run 05-self-healing.txt kubectl get pods -n $NS -l app.kubernetes.io/name=backend
run 05-self-healing.txt curl -s http://localhost:8080/api/health
echo "## database pod restart - data must survive (PersistentVolume)" >> "$OUT/05-self-healing.txt"
BEFORE=$(curl -s http://localhost:8080/api/notes | grep -o '"id"' | wc -l)
run 05-self-healing.txt kubectl delete pod postgres-0 -n $NS
sleep 5
run 05-self-healing.txt kubectl wait --for=condition=ready pod/postgres-0 -n $NS --timeout=120s
sleep 8
AFTER=$(curl -s http://localhost:8080/api/notes | grep -o '"id"' | wc -l)
echo "Notes before restart: $BEFORE   after restart: $AFTER" >> "$OUT/05-self-healing.txt"

# --- 4. Security settings are really in effect ----------------------------------------
start 06-security-checks.txt "Container security checks"
for c in frontend backend worker; do
  echo "## $c" >> "$OUT/06-security-checks.txt"
  run 06-security-checks.txt kubectl exec -n $NS deploy/$c -- id
  # The error text matters: "Read-only file system" proves readOnlyRootFilesystem
  # works (a plain "Permission denied" would only show the user isn't root).
  run 06-security-checks.txt kubectl exec -n $NS deploy/$c -- sh -c "touch /evil-file 2>&1 || true; touch /tmp/allowed && echo '/tmp is writable (emptyDir volume, expected)'"
  run 06-security-checks.txt kubectl exec -n $NS deploy/$c -- sh -c "ls /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null && echo 'TOKEN MOUNTED' || echo 'no Kubernetes API token mounted (expected)'"
done
echo "## securityContext of every pod" >> "$OUT/06-security-checks.txt"
run 06-security-checks.txt kubectl get pods -n $NS -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName,RUN_AS_USER:.spec.securityContext.runAsUser,NON_ROOT:.spec.securityContext.runAsNonRoot,READ_ONLY_FS:.spec.containers[0].securityContext.readOnlyRootFilesystem,PRIV_ESC:.spec.containers[0].securityContext.allowPrivilegeEscalation,CAPS_DROP:.spec.containers[0].securityContext.capabilities.drop'
echo "## images in use (pinned git-SHA tags, never latest)" >> "$OUT/06-security-checks.txt"
run 06-security-checks.txt kubectl get pods -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
echo "## the ConfigMap holds no secrets" >> "$OUT/06-security-checks.txt"
run 06-security-checks.txt kubectl get configmap app-config -n $NS -o jsonpath='{.data}'

# --- 5. NetworkPolicy and image scan proofs (separate scripts) ---------------------------
echo "  -> network policy tests"
./scripts/test-network-policies.sh > /dev/null 2>&1 && echo "     all passed" || echo "     SOME FAILED - check $OUT/network-policy-tests.txt"

echo
echo "Done. Evidence folder:"
ls -1 "$OUT"
