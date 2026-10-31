#!/usr/bin/env bash
# Installs Jenkins into the "jenkins" namespace, entirely from code:
#   namespace -> credentials Secret -> RBAC -> Helm chart (values + JCasC)
#
# Usage: ./scripts/install-jenkins.sh      (safe to re-run: it upgrades in place)
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

CHART_VERSION="5.10.2"            # pinned chart version -> Jenkins 2.580.2
NAMESPACE="jenkins"

# --- 1. Namespaces ------------------------------------------------------------------
# devops-app must exist too: the deployer's RoleBinding lives there.
for ns in "$NAMESPACE" devops-app; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- 2. Registry credential (value from a gitignored file, never from Git) ----------
if [ -f secrets/ghcr.env ]; then
  # shellcheck disable=SC1091
  source secrets/ghcr.env
else
  echo "WARNING: secrets/ghcr.env not found (see jenkins/secrets.example.env)."
  echo "         Installing with a placeholder - CI will fail at the push stage until it exists."
  GHCR_USER="placeholder"; GHCR_TOKEN="placeholder"
fi
kubectl create secret generic jenkins-ghcr -n "$NAMESPACE" \
  --from-literal=username="$GHCR_USER" --from-literal=token="$GHCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 3. ServiceAccounts + least-privilege RBAC for the agents -------------------------
kubectl apply -f jenkins/rbac.yaml

# --- 4. Jenkins itself ------------------------------------------------------------------
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null
echo "==> Installing Jenkins (chart $CHART_VERSION) - first run downloads plugins, takes a few minutes"
helm upgrade --install jenkins jenkins/jenkins \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  -f jenkins/values.yaml \
  --wait --timeout 15m

echo
echo "==> Jenkins is up: http://jenkins.localhost:8080"
echo "    user:     admin"
echo "    password: kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d"
