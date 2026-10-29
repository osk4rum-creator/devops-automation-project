#!/usr/bin/env bash
# Scans the app images (and the Postgres image) for known vulnerabilities
# with Trivy. Full reports are saved as evidence; a summary is printed.
#
# Usage: ./scripts/scan-images.sh            (tag = current git commit)
#        TAG=abc1234 ./scripts/scan-images.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
TAG="${TAG:-$(git rev-parse --short HEAD)}"
OUT=evidence/task3/image-scans
mkdir -p "$OUT"

IMAGES="devops-app/frontend:$TAG devops-app/backend:$TAG devops-app/worker:$TAG $(grep -E '^\s+image: postgres' helm/devops-app/values.yaml | awk '{print $2}')"

printf '%-36s %8s %6s   %s\n' IMAGE CRITICAL HIGH "FIXABLE (HIGH+CRITICAL)"
for img in $IMAGES; do
  name="$(echo "$img" | tr '/:' '__')"
  # Full human-readable report (evidence)
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL \
    --format table --output "$OUT/$name.txt" "$img"
  # Machine-readable counts for the summary line
  json="$(trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --format json "$img")"
  # grep -c prints 0 but exits non-zero when nothing matches; "|| true" keeps
  # set -e from aborting the script on a clean image.
  crit=$(echo "$json" | grep -c '"Severity": *"CRITICAL"' || true)
  high=$(echo "$json" | grep -c '"Severity": *"HIGH"' || true)
  fixable=$(echo "$json" | grep -c '"FixedVersion": *"[^"]' || true)
  printf '%-36s %8s %6s   %s\n' "$img" "$crit" "$high" "$fixable"
done
echo
echo "Full reports: $OUT/"
