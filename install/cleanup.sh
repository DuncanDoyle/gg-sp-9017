#!/bin/sh
# Reset this reproducer to the state before install/setup.sh and test runs.
#
# This only removes resources created by setup.sh and test scripts. It does not
# uninstall Gloo Gateway or delete the gloo-system namespace.

set -u

cd "$(dirname "$0")/.."

echo "Deleting VirtualServices..."
kubectl delete -f virtualservices/svc-002-vs.yaml --ignore-not-found=true
kubectl delete -f virtualservices/svc-001-vs.yaml --ignore-not-found=true

echo ""
echo "Deleting failing-jwks Upstream..."
kubectl delete -f upstreams/failing-jwks-upstream.yaml --ignore-not-found=true

echo ""
echo "Deleting Edge API Gateway..."
kubectl delete -f gateways/gateway-proxy.yaml --ignore-not-found=true

echo ""
echo "Deleting HTTPBin application..."
kubectl delete -f apis/httpbin.yaml --ignore-not-found=true

echo ""
echo "Deleting httpbin namespace..."
kubectl delete namespace httpbin --ignore-not-found=true

echo ""
echo "Cleanup complete."
