#!/usr/bin/env bash
# Stops the public tunnel: the trycloudflare.com URL stops working immediately.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
kubectl delete namespace tunnel --ignore-not-found --wait=true
echo "==> Tunnel stopped - the app is local-only again"
