# Zero-Sidecar Agent Access Control via Istio Waypoint + ext_authz

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using Istio ambient mesh waypoints and a shared ext_authz service for RFC 8693 token exchange.

## Architecture

```
                                                           tool-ns
                                                    ┌─────────────────────────────────────────┐
                                                    │                                         │
User ──── token ────> Agent Pod ─── forward ───> Waypoint (L7) ──── exchanged ────> Tool Pod  │
(out-of-band)         (agent-ns)    token        │                   token          (tool-ns)  │
aud=echo-agent        1 container                │ ext_authz                       1 container │
                                                 │ ┌─────────────────────────┐                │
                                                 │ │ token-exchange-service  │                │
                                                 │ │ • validate JWT (JWKS)   │                │
                                                 │ │ • exchange → aud=echo-  │                │
                                                 │ │   tool (RFC 8693)       │                │
                                                 │ │ • replace Authorization │                │
                                                 │ └────────────┬────────────┘                │
                                                 │              │                             │
                                                 │              ▼                             │
                                                 │         Keycloak                           │
                                                 │    Standard Token Exchange V2              │
                                                 └────────────────────────────────────────────┘
```

**Token flow:**

1. A user obtains a token out-of-band from Keycloak with `aud=echo-agent`
2. The user calls `echo-agent` with this token
3. `echo-agent` forwards the token to `echo-tool`
4. The waypoint intercepts the request and the ext_authz service:
   - Validates the JWT (signature, issuer, expiry) via Keycloak JWKS
   - Exchanges it for a tool-scoped token with `aud=echo-tool` via RFC 8693
   - Replaces the `Authorization` header
5. `echo-tool` receives the exchanged token (not the user's original)

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
| `echo-agent` | `cmd/echo-agent/` | Receives a user token (`aud=echo-agent`), forwards it to echo-tool |
| `echo-tool` | `cmd/echo-tool/` | Echoes request headers as JSON — used to verify the exchanged token |
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

## Keycloak Configuration

The setup script (`deploy/03-keycloak-setup.sh`) configures kagenti's Keycloak using the **Standard Token Exchange V2** (Keycloak 26+ built-in, no feature flags required):

1. **Creates realm** `waypoint-poc` with three clients: `echo-agent`, `echo-tool`, `token-exchange-service`
2. **Enables standard token exchange** (`standard.token.exchange.enabled`) on `token-exchange-service` and `echo-tool`
3. **Adds audience mappers**:
   - `echo-agent` tokens include `echo-agent` as the primary audience and `token-exchange-service` (required by Keycloak standard token exchange — the requesting client must be in the subject token's `aud` claim)
   - `token-exchange-service` lists `echo-tool` as a valid audience target

No legacy feature flags (`--features=token-exchange,admin-fine-grained-authz`) or fine-grained admin permissions are needed.

## End-to-End Tests

The tests simulate a user calling `echo-agent` with a token, which then forwards the request to `echo-tool` through the waypoint:

```
User (curl pod, agent-ns)
  │
  │  POST /call-tool
  │  Authorization: Bearer <user-token, aud=echo-agent>
  ▼
echo-agent (agent-ns)
  │
  │  GET /echo (forwards user token)
  ▼
ztunnel ──── L4 mTLS ────> waypoint (tool-ns)
                              │
               ┌──────────────┴──────────────────┐
               │  1. CUSTOM AuthorizationPolicy   │
               │     → ext_authz gRPC call        │
               │     → token-exchange-service     │
               │       • validate JWT (JWKS)      │
               │       • exchange token (RFC 8693) │
               │       • replace Authorization    │
               │                                  │
               │  2. ALLOW AuthorizationPolicy    │
               │     → only agent-ns permitted    │
               └──────────────┬──────────────────┘
                              ▼
                        echo-tool (tool-ns)
                              │
                              └─ Returns headers as JSON
```

`echo-tool` returns all received headers as JSON, allowing the test to inspect the `Authorization` header and verify whether token exchange occurred.

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | User sends invalid token to echo-agent | echo-agent forwards it; waypoint rejects (HTTP 401/403) |
| **Valid token exchanged** | User sends valid token (`aud=echo-agent`) to echo-agent | echo-agent forwards it; waypoint exchanges it; echo-tool receives `aud=echo-tool` |

```bash
make test
```

## Known Constraints

- **CUSTOM action does not support `from.source.namespaces`** — Istio validation rejects it. Use a separate ALLOW policy for namespace filtering (defense-in-depth).
- **Standard token exchange requires requesting client in subject token audience** — Keycloak mandates that `token-exchange-service` is in the `aud` claim of the agent's token. This is configured via an audience mapper on the `echo-agent` client.
- **Keycloak token issuer URL may differ from internal service URL** — The `iss` claim uses the external hostname (e.g., `keycloak.localtest.me`). The token-exchange-service needs a separate `ISSUER_URL` config for JWT validation while using the internal URL for API calls.
- **Distroless images have no shell** — The test script uses a curl debug pod in agent-ns instead of `kubectl exec` into the workload pod.

## Design Details

See [docs/design.md](docs/design.md) for detailed design decisions, Istio API usage, and limitations.
