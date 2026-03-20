#!/usr/bin/env bash
# Install Istio with ambient profile and register the ext_authz provider.
set -euo pipefail

echo "=== Installing Istio ambient mesh ==="

# Install Istio with ambient profile + extensionProviders for ext_authz
istioctl install -y --set profile=ambient \
  --set "meshConfig.extensionProviders[0].name=kagenti-token-exchange" \
  --set "meshConfig.extensionProviders[0].envoyExtAuthzGrpc.service=token-exchange-service.kagenti-system.svc.cluster.local" \
  --set "meshConfig.extensionProviders[0].envoyExtAuthzGrpc.port=9090"

echo "=== Waiting for Istio components ==="
kubectl wait --for=condition=available deployment/istiod -n istio-system --timeout=120s
kubectl wait --for=condition=ready pod -l app=ztunnel -n istio-system --timeout=120s

echo "=== Installing Gateway API CRDs (required for waypoints) ==="
kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "=== Istio ambient mesh installed ==="
