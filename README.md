# Zero-Sidecar Agent Access Control via Istio Waypoint + ext_authz

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using Istio ambient mesh waypoints and a shared ext_authz service for RFC 8693 token exchange.

## Architecture

```
┌─────────────────┐     ┌──────────┐     ┌───────────────────┐     ┌─────────────────┐
│  Agent Pod      │────>│ ztunnel  │────>│ Waypoint (L7)     │────>│  Tool Pod       │
│  (1 container)  │     │ (L4 mTLS)│     │                   │     │  (1 container)  │
│                 │     │          │     │ AuthzPolicy CUSTOM│     │                 │
│  HTTP + JWT     │     └──────────┘     │   → ext_authz ────┼──┐  │  Echo headers   │
└─────────────────┘                      └───────────────────┘  │  └─────────────────┘
                                                                │
                                              ┌─────────────────┘
                                              ▼
                                    ┌──────────────────────┐
                                    │ token-exchange-svc   │
                                    │ (shared, kagenti-sys)│
                                    │ Validates JWT        │
                                    │ Exchanges token      │
                                    │ Returns new AuthZ    │
                                    └──────────────────────┘
                                              │
                                              ▼
                                    ┌──────────────────────┐
                                    │ Keycloak (RFC 8693)  │
                                    └──────────────────────┘
```

## What This Proves

| Property | AuthBridge (current) | Waypoint PoC |
|----------|---------------------|--------------|
| Containers per agent pod | 5 (envoy, go-processor, spiffe-helper, 2 init) | 1 |
| Memory overhead per pod | ~150-200MB | 0 (shared waypoint) |
| NET_ADMIN / iptables | Required | Not needed |
| HTTP_PROXY env vars | Required | Not needed |
| Token exchange | Per-pod sidecar | Shared waypoint ext_authz |
| Access control | Sidecar code | Declarative AuthorizationPolicy CRs |

## Quick Start

```bash
# Prerequisites: kind, istioctl, kubectl, docker, jq

# Full setup + deploy + test
make all

# Or step by step:
make setup    # Kind cluster + Istio ambient + Keycloak
make deploy   # Build images + deploy workloads
make test     # Run E2E validation

# Cleanup
make teardown
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| `echo-tool` | `cmd/echo-tool/` | HTTP server that echoes request headers (the "tool") |
| `echo-agent` | `cmd/echo-agent/` | HTTP client that calls echo-tool with JWT (the "agent") |
| `token-exchange-service` | `cmd/token-exchange-service/` | ext_authz gRPC service: JWT validation + RFC 8693 token exchange |

## How It Works

1. Agent pod sends HTTP request to `echo-tool.tool-ns.svc` with `Authorization: Bearer <agent-token>`
2. ztunnel intercepts and routes to the waypoint proxy (L4 mTLS)
3. Waypoint evaluates `AuthorizationPolicy` with `action: CUSTOM`
4. Waypoint calls `token-exchange-service` via ext_authz gRPC
5. Token exchange service:
   - Validates the agent's JWT (signature, issuer, expiry) via Keycloak JWKS
   - Determines target audience from the Host header
   - Calls Keycloak RFC 8693 token exchange to get a tool-scoped token
   - Returns the exchanged token via `OkHttpResponse.headers_to_set`
6. Waypoint replaces the `Authorization` header and forwards to echo-tool
7. Echo-tool receives the request with `aud: echo-tool` token (not the agent's original)

## Validated Results

All key risks from the design phase have been tested on a Kind cluster with Istio 1.24 ambient mesh:

| Risk | Status | Finding |
|------|--------|---------|
| Does ext_authz `headers_to_set` replace the Authorization header? | **Confirmed** | Tool received the exchanged token, not the agent's original |
| Does CUSTOM AuthorizationPolicy trigger on the waypoint (not ztunnel)? | **Confirmed** | ext_authz logs show validation + exchange on each request |
| Does the waypoint forward the original Authorization header? | **Confirmed** | CheckRequest includes the agent's JWT for validation |
| Cross-namespace connectivity (kagenti-system → keycloak) | **Confirmed** | Token exchange service reaches Keycloak across namespaces |
| Latency | **Not yet benchmarked** | Qualitatively fast; cache-hit path skips Keycloak entirely |

### Discovered Constraints

- **CUSTOM action does not support `from.source.namespaces`** — Istio validation rejects it. Use a separate ALLOW policy for namespace filtering (defense-in-depth).
- **Keycloak 26 requires explicit feature versions** — `admin-fine-grained-authz:v1` (with `:v1`) must be specified; without the version suffix, Keycloak silently ignores it.
- **Keycloak token issuer URL may differ from internal service URL** — The `iss` claim uses the external hostname (e.g., `keycloak.localtest.me`). The token-exchange-service needs a separate `ISSUER_URL` config for JWT validation while using the internal URL for API calls.
- **Distroless images have no shell** — The test script uses a curl debug pod in agent-ns instead of `kubectl exec` into the workload pod.

## Design Details

See [docs/design.md](docs/design.md) for detailed design decisions, Istio API usage, and limitations.
