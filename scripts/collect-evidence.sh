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

# Read-only demo mode: send the admin token (from the gitignored file) on changes.
# Only the header is passed to curl - the token itself never appears in the evidence.
AUTH=()
if [ -f secrets/admin.env ]; then AUTH=(-H "Authorization: Bearer $(sed -n 's/^token=//p' secrets/admin.env)"); fi
# run() logs the command line, so authenticated calls go through this wrapper instead
acurl() { curl "${AUTH[@]}" "$@"; }

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

# --- 2. The app works end to end (StatusPulse) ------------------------------------
start 04-app-tests.txt "Application tests - StatusPulse"
run 04-app-tests.txt curl -s -o "$OUT/.page.html" -w "HTTP %{http_code} from the dashboard through the Ingress\n" http://localhost:8080/
run 04-app-tests.txt curl -s http://localhost:8080/api/health
run 04-app-tests.txt curl -s http://localhost:8080/api/version
echo "## frontend -> backend (from inside a frontend pod)" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt kubectl exec -n $NS deploy/frontend -- wget -qO- http://backend:8000/healthz
echo "## write: add a monitor through the API (stored in PostgreSQL)" >> "$OUT/04-app-tests.txt"
echo "## read-only demo mode: the same request WITHOUT the admin token is refused" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt curl -s -X POST -H "Content-Type: application/json" -d '{"name":"Evidence check","url":"https://example.com","interval_seconds":30}' http://localhost:8080/api/monitors
echo "## ...and accepted WITH the token (sent as Authorization header, not shown)" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt acurl -s -X POST -H "Content-Type: application/json" -d '{"name":"Evidence check","url":"https://example.com","interval_seconds":30}' http://localhost:8080/api/monitors
echo "## SSRF protection: internal targets are rejected" >> "$OUT/04-app-tests.txt"
for u in http://169.254.169.254/latest/meta-data http://postgres:5432 http://10.43.0.10 file:///etc/passwd; do
  run 04-app-tests.txt acurl -s -X POST -H "Content-Type: application/json" -d "{\"name\":\"attack\",\"url\":\"$u\"}" http://localhost:8080/api/monitors
done
echo "## worker checks the sites (waiting up to 60s for the new monitor's first check)" >> "$OUT/04-app-tests.txt"
for i in $(seq 1 12); do
  curl -s http://localhost:8080/api/monitors | python -c "import sys,json; m=[x for x in json.load(sys.stdin) if x['name']=='Evidence check']; sys.exit(0 if m and m[0]['last_checked_at'] else 1)" && break
  sleep 5
done
echo "## read: monitors with status, last response time and 24h uptime" >> "$OUT/04-app-tests.txt"
curl -s http://localhost:8080/api/monitors | python -c "
import sys, json
for m in json.load(sys.stdin):
    print(f\"  {m['name']:<20} {m['status']:<8} last={m['last_response_ms']} ms  uptime24h={m['uptime_24h']}%  checks={len(m['spark'])}  {m['last_error'] or ''}\")" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt curl -s http://localhost:8080/api/summary
echo "## incidents (opened by the worker, SNS email sent on DOWN / RECOVERED)" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt curl -s http://localhost:8080/api/incidents
run 04-app-tests.txt kubectl logs deploy/worker -n $NS --tail=8
echo "## stored in PostgreSQL" >> "$OUT/04-app-tests.txt"
run 04-app-tests.txt psql_q "SELECT m.name, count(c.id) AS checks, round(avg(c.ok::int)*100, 1) AS uptime_pct FROM monitors m LEFT JOIN checks c ON c.monitor_id = m.id GROUP BY m.name ORDER BY m.name;"
echo "## S3: export a report (private bucket, presigned link valid 1h)" >> "$OUT/04-app-tests.txt"
REPORT=$(acurl -s -X POST http://localhost:8080/api/reports)
echo "$REPORT" | python -c "import sys,json; d=json.load(sys.stdin); print('  s3 key:', d.get('s3_key', d)); print('  presigned link:', 'X-Amz-Signature' in d.get('url',''))" >> "$OUT/04-app-tests.txt"
URL=$(echo "$REPORT" | python -c "import sys,json; print(json.load(sys.stdin).get('url',''))")
echo "## download through the presigned link (first lines of the CSV):" >> "$OUT/04-app-tests.txt"
curl -s "$URL" | head -4 >> "$OUT/04-app-tests.txt"
KEY=$(echo "$REPORT" | python -c "import sys,json; print(json.load(sys.stdin).get('s3_key',''))")
CODE=$(curl -s -o "$OUT/.s3.txt" -w '%{http_code}' "https://devops-app-uploads-890319879195.s3.eu-central-1.amazonaws.com/$KEY"); rm -f "$OUT/.s3.txt"
echo "## same object WITHOUT the link (bucket is private): HTTP $CODE" >> "$OUT/04-app-tests.txt"
# clean up the evidence monitor
ID=$(curl -s http://localhost:8080/api/monitors | python -c "import sys,json; print(next((m['id'] for m in json.load(sys.stdin) if m['name']=='Evidence check'), ''))")
[ -n "$ID" ] && acurl -s -X DELETE http://localhost:8080/api/monitors/$ID > /dev/null
rm -f "$OUT/.page.html"

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
BEFORE=$(psql_q 'SELECT count(*) FROM checks;' | sed -n 3p | tr -d ' ')
run 05-self-healing.txt kubectl delete pod postgres-0 -n $NS
sleep 5
run 05-self-healing.txt kubectl wait --for=condition=ready pod/postgres-0 -n $NS --timeout=120s
sleep 8
AFTER=$(psql_q 'SELECT count(*) FROM checks;' | sed -n 3p | tr -d ' ')
echo "Stored checks before restart: $BEFORE   after restart: $AFTER (>= before: data kept, worker keeps adding)" >> "$OUT/05-self-healing.txt"

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
