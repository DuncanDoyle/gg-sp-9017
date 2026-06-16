#!/bin/sh
# Verifies whether the JWT plugin's provider configuration in Gloo's
# translation gets duplicated across filter chains.
#
# Setup expected (run install/setup-tls-amplification.sh first):
#   5 TLS VirtualServices, each with a distinct secretRef (tls-svc-001 ..
#   tls-svc-005) AND a distinct JWT provider (provider-001 .. provider-005).
#
# Expected (if each VS's JWT config maps to its own filter chain only):
#   Filter chain N contains exactly 1 provider — provider-N.
#
# Actual claim being tested (per colleague's observation on solo-projects#9017):
#   EVERY filter chain contains ALL 5 providers (provider-001 .. provider-005),
#   producing 5 chains × 5 providers = 25 JwksAsyncFetcher instances per config
#   generation regardless of in-drain leak.
#
# Prereq: the Envoy admin interface must be reachable on http://localhost:19000.
# If you have not port-forwarded yet, run:
#   kubectl port-forward -n gloo-system deploy/gateway-proxy 19000:19000

set -eu

ADMIN_URL="${ADMIN_URL:-http://localhost:19000}"
LISTENER_NAME="${LISTENER_NAME:-listener-::-8443}"

# Check admin reachability
if ! curl -sf -m 3 "${ADMIN_URL}/ready" >/dev/null 2>&1; then
  echo "ERROR: Cannot reach Envoy admin at ${ADMIN_URL}. Port-forward first:"
  echo "  kubectl port-forward -n gloo-system deploy/gateway-proxy 19000:19000"
  exit 1
fi

DUMP_FILE="$(mktemp)"
trap 'rm -f "$DUMP_FILE"' EXIT
curl -sf "${ADMIN_URL}/config_dump" > "$DUMP_FILE"

echo "=== Per-filter-chain JWT provider report for listener '${LISTENER_NAME}' ==="
echo ""

python3 - "$DUMP_FILE" "$LISTENER_NAME" <<'PY'
import json, sys

dump_path, target_listener = sys.argv[1], sys.argv[2]
with open(dump_path) as f:
    dump = json.load(f)

SOLO_JWT_TYPE = "type.googleapis.com/envoy.config.filter.http.solo_jwt_authn.v2.JwtWithStage"

def iter_listeners(dump):
    """Yield (name, listener_proto) for every active dynamic + static listener."""
    for cfg in dump.get("configs", []):
        if "ListenersConfigDump" not in cfg.get("@type", ""):
            continue
        for dl in cfg.get("dynamic_listeners", []):
            state = dl.get("active_state") or {}
            listener = state.get("listener") or {}
            yield listener.get("name", dl.get("name", "?")), listener
        for sl in cfg.get("static_listeners", []):
            listener = sl.get("listener") or {}
            yield listener.get("name", "?"), listener

def find_listener(dump, name):
    for n, listener in iter_listeners(dump):
        if n == name:
            return listener
    return None

def jwt_providers_in_filter_chain(fc):
    """Return list of provider names found in the solo_jwt_authn_staged filter on this chain."""
    for nf in fc.get("filters", []):
        tc = nf.get("typed_config", {})
        # Network filter is HCM; look inside its http_filters
        for hf in tc.get("http_filters", []):
            hf_tc = hf.get("typed_config", {})
            if hf_tc.get("@type") == SOLO_JWT_TYPE:
                jwt_authn = hf_tc.get("jwt_authn", {})
                providers = jwt_authn.get("providers", {})
                return sorted(providers.keys())
    return []

listener = find_listener(dump, target_listener)
if listener is None:
    print(f"Listener '{target_listener}' not found in config_dump. Available listeners:")
    for n, _ in iter_listeners(dump):
        print(f"  - {n}")
    sys.exit(2)

filter_chains = listener.get("filter_chains", [])
print(f"Listener '{target_listener}' has {len(filter_chains)} filter chain(s).")
print("")

total_providers = 0
for idx, fc in enumerate(filter_chains):
    name = fc.get("name") or "<unnamed>"
    sni = fc.get("filter_chain_match", {}).get("server_names", [])
    providers = jwt_providers_in_filter_chain(fc)
    total_providers += len(providers)
    print(f"Filter chain #{idx} ({name})")
    print(f"  SNI: {sni}")
    print(f"  JWT providers ({len(providers)}): {providers}")
    print("")

print(f"TOTAL provider entries across all chains: {total_providers}")
print(f"Distinct providers configured across the listener: "
      f"{len(set(p for fc in filter_chains for p in jwt_providers_in_filter_chain(fc)))}")
print("")

# Verdict
chain_count = len(filter_chains)
all_provider_sets = [jwt_providers_in_filter_chain(fc) for fc in filter_chains]
distinct_providers = set(p for ps in all_provider_sets for p in ps)
if chain_count >= 2 and all(set(ps) == distinct_providers for ps in all_provider_sets):
    print("==> RESULT: Every filter chain contains the SAME (full) set of providers.")
    print("    Provider config is being duplicated across filter chains.")
    print(f"    Effective JwksAsyncFetcher instances per generation: "
          f"{chain_count} chains × {len(distinct_providers)} providers = "
          f"{chain_count * len(distinct_providers)}")
elif chain_count >= 2 and all(len(ps) == 1 for ps in all_provider_sets):
    print("==> RESULT: Each filter chain contains only its own provider.")
    print("    No cross-chain duplication of provider config.")
else:
    print("==> RESULT: Mixed — providers are NOT uniformly distributed across chains.")
    print("    Inspect the per-chain output above.")
PY
