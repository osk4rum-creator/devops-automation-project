#!/usr/bin/env bash
# Builds the 3 images, loads them into the local k3d cluster, creates the
# namespace + secrets, and installs/upgrades the Helm chart.
#
# Usage:  ./scripts/deploy-local.sh
# Images are tagged with the current git commit (short SHA), never "latest".
set -euo pipefail
export MSYS_NO_PATHCONV=1            # Git Bash on Windows: don't rewrite /paths

cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER_NAME:-devops}"
NAMESPACE="devops-app"
SERVICES="frontend backend worker"

# --- 1. Image tag = git commit -------------------------------------------------
if [ -z "${TAG:-}" ]; then
  TAG="$(git rev-parse --short HEAD 2>/dev/null)" || {
    echo "No git commit yet. Run: git add . && git commit -m 'message'"; exit 1; }
  if ! git diff --quiet HEAD -- app/; then
    echo "WARNING: app/ has uncommitted changes - commit them so the tag matches the code."
  fi
fi
echo "==> Image tag: $TAG"

# --- 2. Build and load images ----------------------------------------------------
for s in $SERVICES; do
  echo "==> Building devops-app/$s:$TAG"
  docker build -q -t "devops-app/$s:$TAG" "app/$s"
done
echo "==> Importing images into k3d cluster '$CLUSTER'"
k3d image import $(for s in $SERVICES; do echo "devops-app/$s:$TAG"; done) -c "$CLUSTER"

# --- 3. Namespace ----------------------------------------------------------------
# "create --dry-run | apply" = create if missing, do nothing if it exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- 4. Secrets (values come from gitignored files, never from Git) ---------------
mkdir -p secrets
if [ ! -f secrets/db.env ]; then
  echo "==> Generating secrets/db.env with a random password"
  printf 'DB_USER=app\nDB_PASSWORD=%s\n' "$(openssl rand -hex 16)" > secrets/db.env
fi
kubectl create secret generic db-credentials -n "$NAMESPACE" \
  --from-env-file=secrets/db.env --dry-run=client -o yaml | kubectl apply -f -

if [ -f secrets/aws.env ]; then
  kubectl create secret generic aws-credentials -n "$NAMESPACE" \
    --from-env-file=secrets/aws.env --dry-run=client -o yaml | kubectl apply -f -
else
  echo "==> secrets/aws.env not found - S3 uploads and SNS emails stay disabled"
fi

# --- 5. Install / upgrade the app ---------------------------------------------------
echo "==> Deploying with Helm"
helm upgrade --install devops-app helm/devops-app \
  --namespace "$NAMESPACE" \
  --set image.tag="$TAG" \
  ${HELM_EXTRA_ARGS:-} \
  --wait --timeout 5m

kubectl get pods,svc,ingress -n "$NAMESPACE"
echo
echo "==> Done. Open http://localhost:8080"
