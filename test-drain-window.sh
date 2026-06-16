#!/bin/sh
# Tests whether duplicate JWKS async fetch timers are only retained for the
# listener drain window, or whether they persist beyond drain.
#
# Expected if the listener-drain hypothesis is correct:
#   1. Applying/deleting svc-002 temporarily increases duplicate fetch failures.
#   2. After waiting longer than the listener drain duration, the duplicate count
#      returns to the baseline produced by svc-001.
#
# Override defaults:
#   DRAIN_WAIT_SECONDS=660 SAMPLE_SECONDS=45 ./test-drain-window.sh

set -eu

DRAIN_WAIT_SECONDS="${DRAIN_WAIT_SECONDS:-660}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-45}"
PROPAGATION_WAIT_SECONDS="${PROPAGATION_WAIT_SECONDS:-8}"
LOG_PATTERN="Jwks async fetching"

get_proxy_pod() {
  kubectl get pod -n gloo-system -l gloo=gateway-proxy \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

sample_max_group_count() {
  pod="$1"
  seconds="$2"
  label="$3"

  tmp_file="$(mktemp)"

  echo "" >&2
  echo "=== $label ===" >&2
  echo "Sampling gateway-proxy logs for ${seconds}s..." >&2

  kubectl logs -n gloo-system "$pod" -f --since=1s 2>/dev/null >"$tmp_file" &
  log_pid=$!
  sleep "$seconds"
  kill "$log_pid" 2>/dev/null || true
  wait "$log_pid" 2>/dev/null || true

  total_lines=$(grep -c "$LOG_PATTERN" "$tmp_file" 2>/dev/null || true)
  max_group_count=$(
    awk -v pattern="$LOG_PATTERN" '
      index($0, pattern) {
        # Envoy log lines begin with:
        # [YYYY-MM-DD HH:MM:SS.mmm][thread]...
        # Group by whole second so tiny millisecond skew does not hide duplicates.
        key = $1 " " substr($2, 1, 8)
        counts[key]++
        if (counts[key] > max) {
          max = counts[key]
        }
      }
      END {
        print max + 0
      }
    ' "$tmp_file"
  )

  echo "JWKS failure lines observed: $total_lines" >&2
  echo "Max JWKS failure lines in one second: $max_group_count" >&2
  echo "Sample log lines:" >&2
  grep "$LOG_PATTERN" "$tmp_file" 2>/dev/null | tail -n 12 >&2 || true

  rm -f "$tmp_file"

  printf '%s\n' "$max_group_count"
}

PROXY_POD="$(get_proxy_pod)"

if [ -z "$PROXY_POD" ]; then
  echo "ERROR: No gateway-proxy pod found in gloo-system namespace."
  echo "Run install/setup.sh first."
  exit 1
fi

echo "Using gateway-proxy pod: $PROXY_POD"
echo "Drain wait: ${DRAIN_WAIT_SECONDS}s"
echo "Sample window: ${SAMPLE_SECONDS}s"
echo ""
echo "This test intentionally creates duplicate JWKS async fetch timers, then"
echo "waits beyond the expected listener drain window and checks whether the"
echo "duplicate count returns to the svc-001 baseline."

echo ""
echo "=== Reset to baseline resources ==="
kubectl delete -f virtualservices/svc-002-vs.yaml --ignore-not-found=true
kubectl apply -f upstreams/failing-jwks-upstream.yaml
kubectl apply -f virtualservices/svc-001-vs.yaml
echo "Waiting ${PROPAGATION_WAIT_SECONDS}s for baseline config to settle..."
sleep "$PROPAGATION_WAIT_SECONDS"

baseline_count=$(sample_max_group_count "$PROXY_POD" "$SAMPLE_SECONDS" "Baseline: svc-001 only")

echo ""
echo "=== Trigger duplicate timers ==="
kubectl apply -f virtualservices/svc-002-vs.yaml
echo "Waiting ${PROPAGATION_WAIT_SECONDS}s after applying svc-002..."
sleep "$PROPAGATION_WAIT_SECONDS"
kubectl delete -f virtualservices/svc-002-vs.yaml
echo "Waiting ${PROPAGATION_WAIT_SECONDS}s after deleting svc-002..."
sleep "$PROPAGATION_WAIT_SECONDS"

duplicate_count=$(sample_max_group_count "$PROXY_POD" "$SAMPLE_SECONDS" "Post-update: duplicate timers should be visible")

echo ""
echo "=== Wait beyond listener drain window ==="
echo "Sleeping ${DRAIN_WAIT_SECONDS}s. Override with DRAIN_WAIT_SECONDS if your"
echo "gateway-proxy bootstrap config uses a different drain duration."
sleep "$DRAIN_WAIT_SECONDS"

post_drain_count=$(sample_max_group_count "$PROXY_POD" "$SAMPLE_SECONDS" "Post-drain: check whether duplicates returned to baseline")

echo ""
echo "=== Result ==="
echo "Baseline max per-second failures:    $baseline_count"
echo "Post-update max per-second failures: $duplicate_count"
echo "Post-drain max per-second failures:  $post_drain_count"

if [ "$duplicate_count" -le "$baseline_count" ]; then
  echo ""
  echo "WARNING: The test did not observe duplicate timers after the config update."
  echo "Re-run the test, increase SAMPLE_SECONDS, or inspect gateway-proxy logs manually."
  exit 2
fi

if [ "$post_drain_count" -le "$baseline_count" ]; then
  echo ""
  echo "PASS: duplicate timers returned to baseline after the drain wait."
  echo "This supports the listener-drain retention hypothesis."
  exit 0
fi

echo ""
echo "FAIL: duplicate timers still exceed baseline after the drain wait."
echo "This suggests an additional lifetime leak beyond listener drain retention."
exit 1
