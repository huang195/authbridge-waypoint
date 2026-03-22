# Zero-Sidecar Agent Access Control via Istio Waypoint + ext_authz

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using Istio ambient mesh waypoints and a shared ext_authz service for RFC 8693 token exchange.

## Problem Statement

Kagenti's AuthBridge requires 5 containers per agent pod:
1. Envoy sidecar (ext_proc filter)
2. go-processor (token exchange logic)
3. spiffe-helper (SPIFFE identity)
4. iptables init container (traffic redirection, requires NET_ADMIN)
5. client-registration init container

This adds ~150-200MB memory overhead per pod and requires privileged containers. For multi-tenant environments with many agent pods, this doesn't scale.

## Architecture

```
       agent-ns                                              tool-ns
┌─────────────────────────┐                       ┌──────────────────────────────┐
│                         │                       │                              │
│  Agent Pod              │                       │  tool-waypoint (L7)          │
│  (1 container)          │──── ztunnel (mTLS) ──>│  │                           │
│                         │                       │  ├─ ext_authz                │
│  agent-waypoint (L7)    │                       │  │  • validate JWT (JWKS)    │
│  │                      │                       │  │  • exchange token (8693)  │
│  ├─ ext_authz           │                       │  │  • replace Authorization  │
│  │  • validate inbound  │                       │  ▼                           │
│  │    JWT               │                       │  Tool Pod (1 container)      │
│  ▼                      │                       │                              │
│  (reject or pass)       │                       └──────────────────────────────┘
└─────────────────────────┘
```

**Two waypoints, clear separation of concerns:**

- **agent-waypoint** (agent-ns) — validates inbound JWTs to the agent
- **tool-waypoint** (tool-ns) — exchanges agent tokens for tool-scoped tokens via RFC 8693

Both waypoints use the same shared `token-exchange-service` (ext_authz). The service uses the token's `aud` claim to decide: if `aud` includes the destination service name → pass through (already authorized); if not → exchange via RFC 8693. No configuration needed.

**Token flow:**

1. User calls `echo-agent` with a JWT
2. agent-waypoint validates the JWT (inbound)
3. `echo-agent` forwards the request to `echo-tool`
4. tool-waypoint intercepts and calls ext_authz:
   - Validates the JWT (signature, issuer, expiry)
   - Exchanges it for a tool-scoped token with `aud=echo-tool`
   - Replaces the `Authorization` header
5. `echo-tool` receives the exchanged token

## What This Proves

| Property | AuthBridge (current) | Waypoint PoC |
|----------|---------------------|--------------|
| Containers per agent pod | 5 (envoy, go-processor, spiffe-helper, 2 init) | 1 |
| Memory overhead per pod | ~150-200MB | 0 (shared waypoints) |
| NET_ADMIN / iptables | Required | Not needed |
| HTTP_PROXY env vars | Required | Not needed |
| Token exchange | Per-pod sidecar | Shared waypoint ext_authz |
| Access control | Sidecar code | Declarative AuthorizationPolicy CRs |

## Why ext_authz

| | ext_authz | ext_proc |
|---|-----------|----------|
| Protocol | Unary gRPC (request/response) | Bidirectional gRPC stream |
| Complexity | Simple — one CheckRequest, one CheckResponse | Complex — multiple ProcessingRequest/Response per HTTP transaction |
| Header mutation | `OkHttpResponse.headers_to_set` | `HeaderMutation` in response to `request_headers` phase |
| Istio integration | Native via `AuthorizationPolicy CUSTOM` | Requires `EnvoyFilter` (not recommended for ambient) |
| Shared service | Natural — stateless, one call per request | Harder — stream lifetime tied to connection |

JWT validation and token exchange are both handled in ext_authz (not `RequestAuthentication`) because:
- Single point of logic — validation and exchange are tightly coupled
- Meaningful error messages (`{"error": "token expired"}`) vs generic 401
- No two-phase problem — the waypoint doesn't need to skip validation of the exchanged token

## Waypoint Placement

Istio waypoints are **strictly destination-side** — they intercept traffic going TO services in their namespace, never outbound FROM them. This was validated during the PoC: a workload-level waypoint (`waypoint-for: workload` or `all`) in agent-ns does not see outbound calls to tools in other namespaces.

| Waypoint | Namespace | waypoint-for | Responsibility |
|----------|-----------|-------------|----------------|
| agent-waypoint | agent-ns | all | Inbound JWT validation |
| tool-waypoint | tool-ns | service | Token exchange (RFC 8693) |

**Istio policy chain:**

```
Inbound: User → agent-waypoint → Agent Pod
                    │
                    └─ ext_authz: validate JWT, check aud
                       aud includes "echo-agent" → pass through

Outbound: Agent Pod → ztunnel → tool-waypoint → Tool Pod
                                     │
                                     └─ ext_authz: validate JWT, check aud
                                        aud missing "echo-tool" → exchange via RFC 8693
```

## External Tools via Egress Gateway

For tools outside the cluster, the same ext_authz service works via the Istio **egress gateway**:

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate + exchange
```

A `ServiceEntry` defines the external tool, and an `AuthorizationPolicy CUSTOM` on the egress gateway triggers the same `token-exchange-service`. The audience is derived from the hostname convention (service name = first FQDN segment).

One token-exchange-service handles all destinations:

| Destination | Interception point |
|---|---|
| In-cluster tool (different namespace) | tool-ns waypoint |
| In-cluster tool (same namespace) | namespace waypoint |
| External tool | egress gateway |

## Token Exchange Flow (RFC 8693)

```
token-exchange-service                  Keycloak
        │                                  │
        │  grant_type=token-exchange       │
        │  subject_token=<agent-jwt>       │
        │  audience=echo-tool              │
        │  client_id=token-exchange-service│
        │─────────────────────────────────>│
        │                                  │
        │  { access_token: <tool-jwt>,     │
        │    expires_in: 300 }             │
        │<─────────────────────────────────│
```

The exchanged token has:
- `aud`: `echo-tool` (the target tool's client ID)
- `azp`: `token-exchange-service` (the client that performed the exchange)
- `sub`: same as the original agent token's subject (preserved through exchange)

**Caching**: Exchanged tokens are cached keyed by `(subject_token_hash, audience)` with TTL = `expires_in - 30s`. JWKS keys are refreshed in the background every 15 minutes.

## Keycloak Configuration

Keycloak 26 ships with **Standard Token Exchange V2** built-in — no server-level feature flags needed. This was validated by running E2E tests with Keycloak in production mode with zero preview features.

Configuration (handled by `deploy/03-keycloak-setup.sh`):

1. **Enable standard token exchange** (`standard.token.exchange.enabled = "true"`) on:
   - `token-exchange-service` — the requesting client
   - `echo-tool` — the target audience client

2. **Add audience mappers**:
   - `echo-agent` → `token-exchange-service` (so agent tokens include the exchange service in `aud`)
   - `token-exchange-service` → `echo-tool` (so Keycloak allows exchanging tokens scoped to `echo-tool`)

**Issuer URL split**: The token `iss` claim uses Keycloak's external hostname (e.g., `http://keycloak.localtest.me:8080`), which may differ from the in-cluster service URL. The token-exchange-service uses `KEYCLOAK_URL` for API calls and `ISSUER_URL` for JWT issuer validation.

## Prerequisites

A **kagenti cluster** already deployed locally, providing:

- **Kind cluster** named `kagenti` (override with `CLUSTER_NAME=<name>`)
- **Istio ambient mesh** with the `kagenti-token-exchange` ext_authz provider configured
- **Keycloak 26+** running in the `keycloak` namespace (service: `keycloak-service`)
- **`kagenti-system` namespace** for shared infrastructure

See the [kagenti repository](https://github.com/kagenti/kagenti) for cluster setup instructions.

## Quick Start

```bash
make all        # setup + deploy + test
make teardown   # cleanup (keeps the kagenti cluster)
make help       # see all targets
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| `echo-agent` | `cmd/echo-agent/` | Receives a user token, forwards it to echo-tool |
| `echo-tool` | `cmd/echo-tool/` | Echoes request headers as JSON — verifies the exchanged token |
| `token-exchange-service` | `cmd/token-exchange-service/` | ext_authz gRPC service: JWT validation + RFC 8693 token exchange |

## End-to-End Tests

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | Invalid token → echo-agent → tool-waypoint | ext_authz rejects (HTTP 401) |
| **Valid token exchanged** | Valid token → echo-agent → tool-waypoint | Token exchanged; echo-tool receives `aud=echo-tool`, `sub` preserved |

```bash
make test
```

## Known Constraints

1. **Waypoints are destination-side only** — Istio waypoints intercept traffic going TO services, not FROM. Outbound token exchange requires a waypoint in the tool namespace.
2. **CUSTOM action does not support `from.source.namespaces`** — Namespace filtering must use a separate ALLOW policy.
3. **One waypoint per tool namespace** — each tool namespace needs its own waypoint. Managed declaratively via namespace labels and AuthorizationPolicy CRs.
4. **No mTLS to Keycloak** — the token-exchange-service calls Keycloak over plain HTTP. Production should use TLS.
5. **In-memory cache** — token cache doesn't survive pod restarts. Production could use Redis.
6. **Convention: Keycloak client ID must match K8s service name** — the audience is derived from the hostname. If they differ, the service would need an override mechanism (not yet implemented).
7. **Issuer URL must be configured separately** — when Keycloak's external hostname differs from the internal service name.
