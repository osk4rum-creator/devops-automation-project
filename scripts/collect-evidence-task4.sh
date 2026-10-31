#!/usr/bin/env bash
# Collects the Task 4 evidence (Jenkins, CI run, registry, CD run) into
# evidence/task4/. Uses the latest successful CI and CD builds by default.
#
# Usage: ./scripts/collect-evidence-task4.sh [CI_BUILD_NUMBER] [CD_BUILD_NUMBER]
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source scripts/jenkins-api.sh

OUT=evidence/task4
mkdir -p "$OUT"
NS=devops-app
REGISTRY=ghcr.io/osk4rum-creator

CI=${1:-$(jenkins_api GET '/job/application-ci/lastSuccessfulBuild/api/json?tree=number' | grep -o '[0-9]*' | tail -1)}
CD=${2:-$(jenkins_api GET '/job/application-cd/lastSuccessfulBuild/api/json?tree=number' | grep -o '[0-9]*' | tail -1)}
echo "Collecting Task 4 evidence: CI #$CI, CD #$CD"

run()   { local f="$OUT/$1"; shift; { echo "\$ $*"; "$@" 2>&1; echo; } >> "$f"; }
start() { echo "# $2 - collected $(date '+%Y-%m-%d %H:%M')" > "$OUT/$1"; echo >> "$OUT/$1"; echo "  -> $OUT/$1"; }

# "Stage -> result (duration)" table for a build, from Jenkins' pipeline API
stages() {
  jenkins_api GET "/job/$1/$2/wfapi/describe" | python -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('stages', []):
    print(f\"  {s['name']:<22} {s['status']:<9} {s['durationMillis']/1000:6.1f}s\")
print(f\"  {'TOTAL':<22} {d.get('status',''):<9} {d.get('durationMillis',0)/1000:6.1f}s\")"
}
causes() { jenkins_api GET "/job/$1/$2/api/json?tree=actions[causes[shortDescription]]" | grep -o '"shortDescription":"[^"]*"' | cut -d'"' -f4; }
console() { jenkins_api GET "/job/$1/$2/consoleText"; }

# --- 1. Jenkins installation ----------------------------------------------------------
echo "  -> $OUT/01-jenkins-install.txt"
./scripts/verify-jenkins.sh > /dev/null 2>&1

# --- 2. CI run ------------------------------------------------------------------------------
start 02-ci-run.txt "CI pipeline - application-ci #$CI"
{
  echo "## Started by:"; causes application-ci "$CI"; echo
  echo "## Stages:"; stages application-ci "$CI"; echo
  echo "## Test results (JUnit):"
  jenkins_api GET "/job/application-ci/$CI/testReport/api/json?tree=passCount,failCount,skipCount"; echo; echo
  echo "## Build metadata handed to CD (archived artifact build-metadata.json):"
  jenkins_api GET "/job/application-ci/$CI/artifact/build-metadata.json"; echo; echo
  echo "## Key log lines:"
  console application-ci "$CI" | grep -E "Image tag:|Created Pod|Agent .* is provisioned|All checks passed|passed in|--- (building|scanning|pushing)|@sha256:|Total: [0-9]+|Triggered application-cd|Finished:" \
    | sed -E 's/^\[[0-9TZ:.-]+\] //' | grep -v "^\$ "
} >> "$OUT/02-ci-run.txt"
echo "## Agent pod lifecycle: CI agent pods present now (build finished -> none expected):" >> "$OUT/02-ci-run.txt"
run 02-ci-run.txt kubectl get pods -n jenkins -l jenkins/agent-role=ci

# Trivy reports archived by the CI build
for s in frontend backend worker; do
  jenkins_api GET "/job/application-ci/$CI/artifact/reports/trivy-$s.txt" > "$OUT/ci-trivy-$s.txt" 2>/dev/null || true
done

# --- 3. Images in the registry ---------------------------------------------------------------
TAG=$(jenkins_api GET "/job/application-ci/$CI/artifact/build-metadata.json" | grep -o '"image_tag": *"[^"]*"' | cut -d'"' -f4)
start 03-registry.txt "Images in GHCR for tag $TAG (public, anonymous read)"
for s in frontend backend worker; do
  token=$(curl -s "https://ghcr.io/token?scope=repository:osk4rum-creator/devops-app/$s:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  digest=$(curl -sI -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/osk4rum-creator/devops-app/$s/manifests/$TAG" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | tr -d '\r')
  echo "$REGISTRY/devops-app/$s:$TAG  ->  ${digest:-NOT FOUND}" >> "$OUT/03-registry.txt"
done

# --- 4. CD run + cluster state ---------------------------------------------------------------
start 04-cd-run.txt "CD pipeline - application-cd #$CD"
{
  echo "## Started by:"; causes application-cd "$CD"; echo
  echo "## Parameters:"
  jenkins_api GET "/job/application-cd/$CD/api/json?tree=actions[parameters[name,value]]" | grep -o '"name":"[A-Z_]*","value":"[^"]*"' | sed 's/"name":"//; s/","value":"/ = /; s/"$//'; echo
  echo "## Stages:"; stages application-cd "$CD"; echo
  echo "## Key log lines:"
  console application-cd "$CD" | grep -E "version \(image tag\)|target (cluster|namespace)|started by:|from CI build|^ *(frontend|backend|worker) +sha256|serviceaccount|may deploy|REVISION:|successfully rolled out| -> ghcr|web page OK|\"status\"|DEPLOYED|Finished:" \
    | sed -E 's/^\[[0-9TZ:.-]+\] //' | grep -v "^+ "
  echo
} >> "$OUT/04-cd-run.txt"
run 04-cd-run.txt kubectl get deployments,pods,services,ingress -n $NS
for d in frontend backend worker; do run 04-cd-run.txt kubectl rollout status deployment/$d -n $NS; done
run 04-cd-run.txt kubectl get pods -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
run 04-cd-run.txt kubectl get events -n $NS --sort-by=.metadata.creationTimestamp
run 04-cd-run.txt helm history devops-app -n $NS --max 10
echo "## Running version matches CI tag $TAG:" >> "$OUT/04-cd-run.txt"
for d in frontend backend worker; do
  img=$(kubectl get deployment $d -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}')
  [ "$img" = "$REGISTRY/devops-app/$d:$TAG" ] && echo "  $d: $img  OK" || echo "  $d: $img  (differs from CI tag $TAG)"
done >> "$OUT/04-cd-run.txt"

echo
echo "Done:"; ls -1 "$OUT"
