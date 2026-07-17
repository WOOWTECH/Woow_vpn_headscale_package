#!/usr/bin/env bash
# WoowTech Headscale VPN Package — one-shot deployment script
# Usage: ./scripts/deploy.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Phase 1: Install headscale-operator (Helm chart 0.5.0 = app v0.6.0)"
kubectl create ns headscale-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install headscale-operator \
  oci://ghcr.io/infradohq/headscale-operator/charts/headscale-operator \
  --version 0.5.0 -n headscale-system

echo "==> Waiting for operator to be ready..."
kubectl wait --for=condition=ready pod -l control-plane=controller-manager \
  -n headscale-system --timeout=120s

echo "==> Verify CRDs"
kubectl get crd | grep headscale

echo "==> Phase 2: Deploy tenant Headscale instance"
kubectl apply -f "$REPO_ROOT/manifests/tenant/01-namespace.yaml"
kubectl apply -f "$REPO_ROOT/manifests/tenant/02-headscale-cr.yaml"
kubectl apply -f "$REPO_ROOT/manifests/tenant/03-headscale-user.yaml"

echo "==> Waiting for Headscale pod..."
sleep 10
kubectl wait --for=condition=ready pod/headscale-0 -n tenant-test --timeout=180s

echo "==> Phase 3: Deploy Headplane web UI"
echo "    Generating cookie secret..."
COOKIE_SECRET=$(openssl rand -hex 16)
kubectl create secret generic headplane-secrets \
  --from-literal=COOKIE_SECRET="$COOKIE_SECRET" \
  -n tenant-test --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$REPO_ROOT/manifests/tenant/06-headplane-configmap.yaml"
kubectl apply -f "$REPO_ROOT/manifests/tenant/07-headplane-deployment.yaml"

echo "==> Phase 4: Create test PreAuthKey"
kubectl apply -f "$REPO_ROOT/manifests/tenant/09-preauth-key.yaml"

echo "==> Done! Next steps:"
echo "  1. Retrieve the auth key:"
echo "     kubectl get secret test-device-preauth-key -n tenant-test -o jsonpath='{.data.key}' | base64 -d"
echo "  2. Expose Headscale externally (see docs/EXTERNAL-ACCESS.md)"
echo "  3. Connect a device:"
echo "     tailscale up --login-server=https://<your-headscale-url> --authkey=<key>"
