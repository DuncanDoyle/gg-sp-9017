#!/bin/sh
# Demonstrates the jwt_authn async fetcher timer leak (solo-projects#9017).
#
# Each config update that touches the jwt_authn filter spawns a new async JWKS
# fetch timer without cancelling the previous one. With a non-reachable JWKS
# endpoint, leaked timers accumulate and produce duplicate log lines that grow
# with every config change.

PROXY_POD=$(kubectl get pod -n gloo-system -l gloo=gateway-proxy -o jsonpath='{.items[0].metadata.name}')

if [ -z "$PROXY_POD" ]; then
  echo "ERROR: No gateway-proxy pod found in gloo-system namespace."
  echo "Run install/setup.sh first."
  exit 1
fi

echo "Using gateway-proxy pod: $PROXY_POD"
echo ""

# -----------------------------------------------------------------------
echo "=== Step 1: Baseline — 1 JWKS failure per interval ==="
echo "(svc-001 is already applied; expect ~1 failure line every 6 seconds)"
echo "Watching logs for 15 seconds..."
echo ""
kubectl logs -n gloo-system "$PROXY_POD" -f --since=1s 2>/dev/null &
LOG_PID=$!
sleep 15
kill $LOG_PID 2>/dev/null
wait $LOG_PID 2>/dev/null

# -----------------------------------------------------------------------
echo ""
echo "=== Step 2: Apply svc-002 to trigger the timer leak ==="
kubectl apply -f virtualservices/svc-002-vs.yaml
echo "Waiting 5 seconds for the config update to propagate to Envoy..."
sleep 5

echo ""
echo "Watching logs for 20 seconds..."
echo "(BUG: expect 2+ failure lines appearing simultaneously at each interval)"
echo ""
kubectl logs -n gloo-system "$PROXY_POD" -f --since=1s 2>/dev/null &
LOG_PID=$!
sleep 20
kill $LOG_PID 2>/dev/null
wait $LOG_PID 2>/dev/null

# -----------------------------------------------------------------------
echo ""
echo "=== Step 3: Delete svc-002 — failure count INCREASES rather than returning to 1 ==="
kubectl delete -f virtualservices/svc-002-vs.yaml
echo "Waiting 5 seconds for config update to propagate..."
sleep 5

echo ""
echo "Watching logs for 20 seconds..."
echo "(BUG: expect 3+ failure lines — each config change adds another leaked timer)"
echo ""
kubectl logs -n gloo-system "$PROXY_POD" -f --since=1s 2>/dev/null &
LOG_PID=$!
sleep 20
kill $LOG_PID 2>/dev/null
wait $LOG_PID 2>/dev/null

# -----------------------------------------------------------------------
echo ""
echo "=== Summary: JWKS failure lines in last 60s ==="
echo "(count per timestamp group shows how many timers are running)"
kubectl logs -n gloo-system "$PROXY_POD" --since=60s 2>/dev/null | grep "Jwks async fetching"
