#!/usr/bin/env bash
# Sets up the GitHub -> Jenkins webhook relay (see jenkins/webhook-relay.yaml).
# Creates a smee.io channel on first run and stores it in secrets/smee.env.
#
# Usage: ./scripts/install-webhook-relay.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

mkdir -p secrets
if [ ! -f secrets/smee.env ]; then
  # smee.io/new redirects to a fresh random channel; read it from the Location header
  url="$(curl -s -I https://smee.io/new | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r')"
  [ -n "$url" ] || { echo "Could not create a smee.io channel"; exit 1; }
  echo "SMEE_URL=$url" > secrets/smee.env
  echo "==> Created channel $url (saved in secrets/smee.env, gitignored)"
fi
source secrets/smee.env

kubectl create secret generic smee-channel -n jenkins --from-literal=url="$SMEE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f jenkins/webhook-relay.yaml
kubectl rollout status deployment/webhook-relay -n jenkins --timeout=180s

cat <<EOF

==> Relay running. One-time step in GitHub (repo -> Settings -> Webhooks -> Add webhook):
    Payload URL:   $SMEE_URL
    Content type:  application/json
    Events:        Just the push event
EOF
