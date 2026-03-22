# Zero-Sidecar Agent Access Control via Istio Waypoint + ext_authz

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using Istio ambient mesh waypoints and a shared ext_authz service for RFC 8693 token exchange.

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

Both waypoints use the same shared `token-exchange-service` (ext_authz). The service auto-distinguishes inbound vs outbound: if the destination host has an audience mapping → exchange; otherwise → validate-only passthrough.

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

## External Tools

For tools outside the cluster, the same ext_authz service works via the Istio **egress gateway**:

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate + exchange
```

One token-exchange-service handles in-cluster waypoints and egress gateway — unified token exchange for all destinations.

## Alternative Approaches

This PoC validates the mesh + ext_authz approach. The [design doc](docs/design.md#alternative-approaches) compares it with two other strategies:

| Approach | Trade-off |
|----------|-----------|
| **Mesh + ext_authz** (this PoC) | Zero agent code changes, requires mesh |
| **SDK / library** | Zero infrastructure, requires agent integration |
| **K8s SA token projection** | Zero runtime exchange, requires OIDC federation per cluster |

## External Tools

For tools outside the cluster, the same ext_authz service works via the Istio **egress gateway**:

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate + exchange
```

One token-exchange-service handles in-cluster waypoints and egress gateway — unified token exchange for all destinations. See [docs/design.md](docs/design.md#external-tools-via-egress-gateway).

## Known Constraints

- **Waypoints are destination-side only** — Istio waypoints intercept traffic going TO services, not FROM. Outbound token exchange requires a waypoint in the tool namespace.
- **CUSTOM action does not support `from.source.namespaces`** — Namespace filtering must use a separate ALLOW policy.
- **Keycloak token issuer URL may differ from internal service URL** — The token-exchange-service needs a separate `ISSUER_URL` for JWT validation.

## Design Details

See [docs/design.md](docs/design.md).
