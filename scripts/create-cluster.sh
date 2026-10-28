#!/usr/bin/env bash
# Creates the local Kubernetes cluster used for Tasks 3-4.
#   1 server (control plane) + 2 agents (workers), running k3s inside Docker.
#   Host port 8080 -> cluster load balancer port 80 (Traefik ingress),
#   so the app is reachable at http://localhost:8080
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-devops}"

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Cluster '$CLUSTER_NAME' already exists"
else
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    -p "8080:80@loadbalancer" \
    --wait
fi

kubectl get nodes -o wide
