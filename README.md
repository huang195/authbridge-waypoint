# Zero-Sidecar Agent Access Control via Istio Waypoint + ext_authz

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using Istio ambient mesh waypoints and a shared ext_authz service for RFC 8693 token exchange.

## Architecture

```
         agent-ns                                                    tool-ns
  ┌──────────────────────────────────────────────────┐        ┌────────────────┐
  │                                                  │        │                │
  │  Agent Pod ──── outbound ────> agent-waypoint ───┼──mTLS──┼──> Tool Pod    │
  │  (1 container)   token         (workload-level)  │        │  (1 container) │
  │                                │                 │        │  (no waypoint) │
  │                                │ ext_authz       │        │                │
  │                  ┌─────────────┴──────────────┐  │        └────────────────┘
  │                  │ token-exchange-service      │  │
  │                  │ • validate JWT (JWKS)       │  │
  │                  │ • exchange → aud=echo-tool  │  │
  │                  │   (RFC 8693)                │  │
  │                  │ • replace Authorization hdr │  │
  │                  └─────────────┬──────────────┘  │
  │                                │                 │
  │                                ▼                 │
  │                           Keycloak               │
  └──────────────────────────────────────────────────┘
```

**Key design**: The waypoint is on the **agent side** (attached to the agent's ServiceAccount), not the tool side. Token validation and exchange happen on behalf of the agent — the tool namespace has no waypoint and no special configuration.

**Token flow:**

1. A user obtains a token out-of-band from Keycloak
2. The user calls `echo-agent` with this token
3. `echo-agent` forwards the token to `echo-tool`
4. The **agent-side waypoint** intercepts the outbound request and the ext_authz service:
   - Validates the JWT (signature, issuer, expiry) via Keycloak JWKS
   - Exchanges it for a tool-scoped token with `aud=echo-tool` via RFC 8693
   - Replaces the `Authorization` header
5. `echo-tool` receives the exchanged token (not the user's original)

Inbound requests TO the agent also go through the waypoint for JWT validation.

## What This Proves

| Property | AuthBridge (current) | Waypoint PoC |
|----------|---------------------|--------------|
| Containers per agent pod | 5 (envoy, go-processor, spiffe-helper, 2 init) | 1 |
| Memory overhead per pod | ~150-200MB | 0 (shared waypoint) |
| NET_ADMIN / iptables | Required | Not needed |
| HTTP_PROXY env vars | Required | Not needed |
| Token exchange | Per-pod sidecar | Shared waypoint ext_authz |
| Security logic location | Tool-side sidecar | Agent-side waypoint |
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
| `echo-agent` | `cmd/echo-agent/` | Receives a user token, forwards it to echo-tool |
| `echo-tool` | `cmd/echo-tool/` | Echoes request headers as JSON — used to verify the exchanged token |
| `token-exchange-service` | `cmd/token-exchange-service/` | ext_authz gRPC service: JWT validation + RFC 8693 token exchange |

## Deploy Manifests

| File | Description |
|------|-------------|
| `deploy/03-keycloak-setup.sh` | Creates waypoint-poc realm, clients, token exchange permissions |
| `deploy/04-namespaces.yaml` | Creates `agent-ns` and `tool-ns` with Istio ambient labels |
| `deploy/05-token-exchange-svc.yaml` | Deploys token-exchange-service in `kagenti-system` |
| `deploy/06-waypoint.yaml` | Workload-level waypoint Gateway in `agent-ns` |
| `deploy/07-istio-policies.yaml` | Outbound token exchange + inbound JWT validation policies |
| `deploy/08-workloads.yaml` | ServiceAccount, echo-agent and echo-tool Deployments + Services |
| `deploy/09-test.sh` | End-to-end validation script |

## End-to-End Tests

```
User (curl pod, agent-ns)
  │
  │  POST /call-tool + Authorization: Bearer <user-token>
  ▼
echo-agent (agent-ns)
  │
  │  GET /echo (forwards user token to echo-tool)
  ▼
agent-waypoint (agent-ns, workload-level)
  │
  ├─ CUSTOM AuthorizationPolicy → ext_authz
  │    • validate JWT (JWKS)
  │    • exchange token (RFC 8693)
  │    • replace Authorization header
  ▼
ztunnel ──── L4 mTLS ────> echo-tool (tool-ns, no waypoint)
                              │
                              └─ Returns headers as JSON
```

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | User sends invalid token to echo-agent | Agent forwards it; agent waypoint rejects (HTTP 401/403) |
| **Valid token exchanged** | User sends valid token to echo-agent | Agent forwards it; agent waypoint exchanges it; echo-tool receives `aud=echo-tool` |

```bash
make test
```

## Known Constraints

- **CUSTOM action does not support `from.source.namespaces`** — Istio validation rejects it. Namespace filtering must use a separate ALLOW policy.
- **Keycloak token issuer URL may differ from internal service URL** — The token-exchange-service needs a separate `ISSUER_URL` config for JWT validation.
- **Distroless images have no shell** — The test script uses curl debug pods instead of `kubectl exec`.

## Design Details

See [docs/design.md](docs/design.md) for detailed design decisions, Istio API usage, and limitations.
