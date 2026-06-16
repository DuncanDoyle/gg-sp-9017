#!/bin/sh
# Generate 5 self-signed TLS keypairs and create them as Kubernetes Secrets.
# Each secret has a different name so Gloo's ConsolidateSslConfigurations
# treats them as distinct SSL configs and produces a separate filter chain
# per VirtualService that references them.

set -eu

NS="${NS:-gloo-system}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for i in 001 002 003 004 005; do
  CN="svc-${i}.example.com"
  KEY="$TMPDIR/svc-${i}.key"
  CRT="$TMPDIR/svc-${i}.crt"

  # Generate self-signed cert (1 day validity — only used to produce a valid SSL config in Envoy)
  openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/CN=${CN}" \
    -addext "subjectAltName=DNS:${CN}" >/dev/null 2>&1

  kubectl create secret tls "tls-svc-${i}" \
    --namespace "$NS" \
    --cert="$CRT" --key="$KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "Created TLS secrets tls-svc-001 ... tls-svc-005 in namespace $NS"
