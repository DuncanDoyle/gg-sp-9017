# jwt_authn async fetcher timer leak on filter config updates

Reproducer for [solo-projects#9017](https://github.com/solo-io/solo-projects/issues/9017).

## Issue summary

When using `asyncFetch` for JWKS in a VirtualService, each config update that touches the `jwt_authn` filter creates a new async fetch timer without cancelling the previous one. With a non-reachable JWKS endpoint, leaked timers accumulate and produce duplicate log lines that grow with every config change. Critically, deleting a VirtualService also triggers a config update, so the failure count *increases* after deletion rather than returning to baseline.

**Expected behavior:** config updates cancel the existing fetch timer and start a fresh one — one timer per JWKS provider regardless of how many config changes have occurred.

**Actual behavior:** each config update that touches `jwt_authn` adds another parallel fetch timer; N config changes → N simultaneous failure log lines per interval.

## Gloo Gateway version

1.21.3 (Edge API / VirtualService)

## Installation

Add the Gloo Gateway Helm repo:
```
helm repo add glooe https://storage.googleapis.com/gloo-ee-helm
```

Export your license key:
```
export GLOO_GATEWAY_LICENSE_KEY=<your license key>
```

Install Gloo Gateway:
```
cd install
./install-gloo-gateway-with-helm.sh
```

## Setup

```
cd install
./setup.sh
```

This deploys:
- The Edge API Gateway
- HTTPBin as the backend
- `svc-001` VirtualService with JWT `asyncFetch` pointing to an unreachable JWKS endpoint (`192.0.2.1` — TEST-NET-1, RFC 5737)

## Steps to reproduce

Run the test script from the project root:

```
./test.sh
```

The script walks through three steps:

1. **Baseline** — with only `svc-001` applied, observe ~1 JWKS failure log line every 6 seconds
2. **Apply `svc-002`** — a second VirtualService with the same JWT provider triggers a config update; observe 2 failure lines appearing simultaneously at each interval
3. **Delete `svc-002`** — another config update adds yet another leaked timer; observe the failure count *increase* to 3+ rather than returning to 1

You can also run the steps manually:

```sh
# Watch baseline (1 failure per interval)
kubectl logs -n gloo-system -l gloo=gateway-proxy -f | grep "Jwks async fetching"

# Trigger the leak
kubectl apply -f virtualservices/svc-002-vs.yaml

# Watch duplicates (2 failures per interval)
kubectl logs -n gloo-system -l gloo=gateway-proxy -f | grep "Jwks async fetching"

# Delete svc-002 — count goes up, not down
kubectl delete -f virtualservices/svc-002-vs.yaml
kubectl logs -n gloo-system -l gloo=gateway-proxy -f | grep "Jwks async fetching"
```

## Root cause

The leak originates in Envoy's `JwksAsyncFetcher` (`jwks_async_fetcher.cc`). When the `jwt_authn` filter is reconstructed during an xDS config update, a new fetcher instance is created without stopping the previous one's timer. This is confirmed by the Envoy config dump being identical before and after — the provider map has a single entry in both cases, so this is a runtime timer leak, not a translation/config duplication issue in Gloo.

## Additional test: JWKS providers per filter chain (TLS amplification)

This test checks whether Gloo's JWT plugin duplicates **all** JWT providers onto **every** filter chain when multiple TLS VirtualServices each have their own SSL config.

### Setup

After the base setup is running, apply the TLS scenario:

```
cd install
./setup-tls-amplification.sh
```

This:
- Generates 5 self-signed TLS keypairs and creates them as `tls-svc-001` ... `tls-svc-005` secrets
- Applies the SSL Gateway listener (`gateway-proxy-ssl`, port 8443)
- Applies 5 TLS VirtualServices (`svc-tls-001-vs.yaml` ... `svc-tls-005-vs.yaml`), each with its own `secretRef`, `sniDomain`, and a **distinct** JWT provider (`provider-001` ... `provider-005`)

### Run the test

Port-forward the Envoy admin interface in a separate terminal:

```
kubectl port-forward -n gloo-system deploy/gateway-proxy 19000:19000
```

Then run:

```
./test-jwks-per-filter-chain.sh
```

The script fetches `/config_dump`, finds the SSL listener (`listener-::-8443`), and reports for each filter chain which JWT providers it contains. **Expected (if Gloo scoped providers per-chain):** filter chain N contains only `provider-N`. **Actual claim being tested:** every filter chain contains all 5 providers, producing `5 chains × 5 providers = 25` `JwksAsyncFetcher` instances per config generation independent of any in-drain timer leak.

### Cleanup

```
cd install
./cleanup-tls-amplification.sh
```

Removes only the TLS scenario resources. The base reproducer (`svc-001`, `svc-002`, gateway-proxy, httpbin, failing-jwks upstream) is left intact.
