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
                                    │ Standard Token       │
                                    │ Exchange V2          │
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

## Prerequisites

This project assumes a **kagenti cluster** is already deployed locally, providing:

- **Kind cluster** named `kagenti` (override with `CLUSTER_NAME=<name>`)
- **Istio ambient mesh** with the `kagenti-token-exchange` ext_authz provider configured
- **Keycloak 26+** running in the `keycloak` namespace (service: `keycloak-service`)
- **`kagenti-system` namespace** for shared infrastructure

See the [kagenti repository](https://github.com/kagenti/kagenti) for cluster setup instructions.

## Quick Start

```bash
# Full setup + deploy + test
make all

# Or step by step:
make setup    # Configure Keycloak realm/clients, deploy namespaces + waypoint
make deploy   # Build images, load into Kind, deploy workloads
make test     # Run E2E validation

# Cleanup (removes deployed resources, keeps the kagenti cluster)
make teardown

# See all targets
make help
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| `echo-tool` | `cmd/echo-tool/` | HTTP server that echoes request headers (the "tool") |
| `echo-agent` | `cmd/echo-agent/` | HTTP client that calls echo-tool with JWT (the "agent") |
| `token-exchange-service` | `cmd/token-exchange-service/` | ext_authz gRPC service: JWT validation + RFC 8693 token exchange |

## Deploy Manifests

| File | Description |
|------|-------------|
| `deploy/03-keycloak-setup.sh` | Creates waypoint-poc realm, clients, enables standard token exchange, adds audience mappers |
| `deploy/04-namespaces.yaml` | Creates `agent-ns` and `tool-ns` with Istio ambient labels |
| `deploy/05-token-exchange-svc.yaml` | Deploys token-exchange-service in `kagenti-system` |
| `deploy/06-waypoint.yaml` | Waypoint Gateway for `tool-ns` |
| `deploy/07-istio-policies.yaml` | CUSTOM (ext_authz) and ALLOW (namespace filter) AuthorizationPolicies |
| `deploy/08-workloads.yaml` | echo-agent and echo-tool Deployments + Services |
| `deploy/09-test.sh` | End-to-end validation script |

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

## Keycloak Configuration

The setup script (`deploy/03-keycloak-setup.sh`) configures kagenti's Keycloak using the **Standard Token Exchange V2** (Keycloak 26+ built-in, no feature flags required):

1. **Creates realm** `waypoint-poc` with three clients: `echo-agent`, `echo-tool`, `token-exchange-service`
2. **Enables standard token exchange** (`standard.token.exchange.enabled`) on `token-exchange-service` and `echo-tool`
3. **Adds audience mappers**:
   - `echo-agent` tokens include `token-exchange-service` in the audience (so the exchange service can present them as `subject_token`)
   - `token-exchange-service` lists `echo-tool` as a valid audience target

No legacy feature flags (`--features=token-exchange,admin-fine-grained-authz`) or fine-grained admin permissions are needed.

## End-to-End Tests

The tests validate the waypoint token exchange using a curl pod in `agent-ns` that calls `echo-tool` through the waypoint:

```
curl pod (agent-ns)                          echo-tool (tool-ns)
     │                                            ▲
     │  GET /echo                                 │
     │  Authorization: Bearer <token>             │
     ▼                                            │
  ztunnel ──── L4 mTLS ────> waypoint ────────────┘
                               │
                ┌──────────────┴──────────────────┐
                │  1. CUSTOM AuthorizationPolicy   │
                │     → ext_authz gRPC call        │
                │     → token-exchange-service     │
                │       • validate JWT (JWKS)      │
                │       • exchange token (RFC 8693)│
                │       • replace Authorization    │
                │                                  │
                │  2. ALLOW AuthorizationPolicy    │
                │     → only agent-ns permitted    │
                └─────────────────────────────────┘
```

`echo-tool` returns all received headers as JSON, allowing the test to inspect the `Authorization` header and verify whether token exchange occurred.

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | `Authorization: Bearer invalid-token-12345` | HTTP 401/403 — waypoint rejects via ext_authz |
| **Valid token exchanged** | `Authorization: Bearer <agent-jwt>` | HTTP 200 — tool receives token with `aud=echo-tool`, not the agent's original |

```bash
make test
```

## Known Constraints

- **CUSTOM action does not support `from.source.namespaces`** — Istio validation rejects it. Use a separate ALLOW policy for namespace filtering (defense-in-depth).
- **Keycloak token issuer URL may differ from internal service URL** — The `iss` claim uses the external hostname (e.g., `keycloak.localtest.me`). The token-exchange-service needs a separate `ISSUER_URL` config for JWT validation while using the internal URL for API calls.
- **Distroless images have no shell** — The test script uses a curl debug pod in agent-ns instead of `kubectl exec` into the workload pod.

## Design Details

See [docs/design.md](docs/design.md) for detailed design decisions, Istio API usage, and limitations.
