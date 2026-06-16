#!/bin/sh
# Remove resources created by setup-tls-amplification.sh.
# Does not touch the base reproducer (svc-001, svc-002, gateway-proxy, httpbin, failing-jwks).

set -u
cd "$(dirname "$0")/.."

echo "Deleting TLS VirtualServices..."
for f in virtualservices/tls/svc-tls-*-vs.yaml; do
  kubectl delete -f "$f" --ignore-not-found=true
done

echo ""
echo "Deleting SSL Gateway listener..."
kubectl delete -f gateways/gateway-proxy-ssl.yaml --ignore-not-found=true

echo ""
echo "Deleting TLS secrets..."
for i in 001 002 003 004 005; do
  kubectl delete secret "tls-svc-${i}" -n gloo-system --ignore-not-found=true
done

echo ""
echo "TLS amplification scenario cleanup complete."
