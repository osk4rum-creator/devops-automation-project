#!/usr/bin/env bash
# Starts the Cloudflare Quick Tunnel and prints the public HTTPS URL.
# The dashboard is read-only for visitors when Secret "app-admin" exists.
#
# Usage: ./scripts/start-tunnel.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

if ! kubectl get secret app-admin -n devops-app >/dev/null 2>&1; then
  echo "Refusing to go public: Secret app-admin (read-only demo mode) is missing."
  echo "Run ./scripts/deploy-local.sh once, or create it from secrets/admin.env."
  exit 1
fi

kubectl apply -f k8s/tunnel/cloudflare-tunnel.yaml
kubectl rollout status deployment/cloudflared -n tunnel --timeout=180s

echo "==> Waiting for Cloudflare to assign a URL..."
for i in $(seq 1 30); do
  url=$(kubectl logs deployment/cloudflared -n tunnel 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true)
  [ -n "$url" ] && break
  sleep 2
done
[ -n "${url:-}" ] || { echo "No URL yet - check: kubectl logs deployment/cloudflared -n tunnel"; exit 1; }

echo
echo "  Public demo:  $url"
echo "  (read-only for visitors; unlock with the token in secrets/admin.env)"
echo "  The URL changes whenever the tunnel restarts. Stop: ./scripts/stop-tunnel.sh"
