#!/bin/sh
# Setup for the JWKS-per-filter-chain amplification test.
#
# Creates 5 TLS VirtualServices, each with a distinct secretRef + sniDomain
# and a distinct JWT provider. Gloo's translation produces 5 separate Envoy
# filter chains on the SSL listener. The test script
# (test-jwks-per-filter-chain.sh) then inspects /config_dump to verify which
# providers ended up in which filter chain.
#
# Pre-req: install/setup.sh must already have been run so that the gloo-system
# namespace, gloo-gateway proxy, httpbin app, and failing-jwks upstream exist.

set -eu
cd "$(dirname "$0")/.."

# Generate the 5 self-signed TLS secrets (tls-svc-001 ... tls-svc-005)
printf "\nGenerate self-signed TLS secrets...\n"
sh secrets/generate-tls-secrets.sh

# Deploy the SSL Gateway listener (port 8443)
printf "\nDeploy SSL Gateway listener ...\n"
kubectl apply -f gateways/gateway-proxy-ssl.yaml

# Deploy the 5 TLS VirtualServices
printf "\nDeploy 5 TLS VirtualServices ...\n"
for f in virtualservices/tls/svc-tls-*-vs.yaml; do
  kubectl apply -f "$f"
done

echo ""
echo "Setup complete. Run ./test-jwks-per-filter-chain.sh to inspect the resulting filter chains."
