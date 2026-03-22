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
│  agent-waypoint (L7)    │                       │  │  aud missing "echo-tool"  │
│  │                      │                       │  │  → exchange via RFC 8693  │
│  ├─ ext_authz           │                       │  │  → replace Authorization  │
│  │  aud has "echo-agent"│                       │  ▼                           │
│  │  → pass through      │                       │  Tool Pod (1 container)      │
│  ▼                      │                       │                              │
└─────────────────────────┘                       └──────────────────────────────┘
```

**Two waypoints, one shared ext_authz service, zero configuration:**

- **agent-waypoint** (agent-ns) — token `aud` includes destination → pass through
- **tool-waypoint** (tool-ns) — token `aud` missing destination → exchange via RFC 8693

The service derives the destination audience from the hostname (convention: K8s service name = first segment of FQDN). No audience maps or direction config needed — the token's `aud` claim is the signal.

**Token flow:**

1. User calls `echo-agent` with a JWT (`aud` includes `echo-agent`)
2. agent-waypoint: ext_authz validates JWT, `aud` includes `echo-agent` → pass through
3. `echo-agent` forwards the request to `echo-tool`
4. tool-waypoint: ext_authz validates JWT, `aud` missing `echo-tool` → exchange
   - Calls Keycloak RFC 8693 token exchange
   - Replaces `Authorization` header with tool-scoped token
5. `echo-tool` receives the exchanged token (`aud=echo-tool`, `sub` preserved)

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
| agent-waypoint | agent-ns | all | `aud` includes destination → pass through |
| tool-waypoint | tool-ns | service | `aud` missing destination → exchange |

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

A `ServiceEntry` defines the external tool, and an `AuthorizationPolicy CUSTOM` on the egress gateway triggers the same `token-exchange-service`. For external hostnames where the convention (first FQDN segment) doesn't map to a Keycloak client ID, an override mechanism would be needed.

One token-exchange-service handles all in-cluster destinations:

| Destination | Interception point |
|---|---|
| In-cluster tool (different namespace) | tool-ns waypoint |
| In-cluster tool (same namespace) | namespace waypoint |
| External tool | egress gateway |

## Keycloak: Setup and Runtime

Keycloak 26 ships with **Standard Token Exchange V2** built-in — no server-level feature flags needed. This was validated by running E2E tests with Keycloak in production mode with zero preview features.

### How Keycloak is used at runtime

The token-exchange-service calls Keycloak twice during its lifecycle:

**1. JWKS fetch** (background, every 15 minutes):
```
GET /realms/waypoint-poc/protocol/openid-connect/certs
→ Returns the realm's RSA public keys for JWT signature verification
```
The service caches these keys and uses them to validate every incoming JWT without calling Keycloak per-request.

**2. Token exchange** (per-request, when `aud` is missing the destination):
```
POST /realms/waypoint-poc/protocol/openid-connect/token

  grant_type         = urn:ietf:params:oauth:grant-type:token-exchange
  subject_token      = <the agent's JWT>
  subject_token_type = urn:ietf:params:oauth:token-type:access_token
  audience           = echo-tool          ← derived from destination hostname
  client_id          = token-exchange-service
  client_secret      = exchange-secret

→ Returns: { access_token: <tool-scoped JWT>, expires_in: 300 }
```

Exchanged tokens are cached keyed by `(subject_token_hash, audience)` with TTL = `expires_in - 30s`, so repeated calls to the same tool skip Keycloak entirely.

### What Keycloak checks during exchange

When the token exchange request arrives, Keycloak validates four things:

```
1. Is token-exchange-service allowed to call the exchange endpoint?
   → Check: standard.token.exchange.enabled = "true" on token-exchange-service
   → Without this: "Client not allowed to exchange"

2. Is the subject_token valid?
   → Check: signature, issuer, expiry (same as any JWT validation)

3. Is token-exchange-service in the subject_token's audience?
   → Check: subject_token.aud includes "token-exchange-service"
   → Without this: "Client not allowed to exchange: not in subject token audience"
   → This is why echo-agent needs the token-exchange-service audience mapper

4. Is echo-tool a valid exchange target?
   → Check: standard.token.exchange.enabled = "true" on echo-tool
   → Check: token-exchange-service has an audience mapper for echo-tool
   → Without this: exchange fails or exchanged token missing correct audience
```

The exchanged token has:
- `aud`: `echo-tool` (the target tool's client ID)
- `azp`: `token-exchange-service` (the client that performed the exchange)
- `sub`: same as the original agent token's subject (preserved through exchange)

### Setup (deploy/03-keycloak-setup.sh)

The setup script configures Keycloak via the admin REST API. Here's what it creates and why:

**Step 1 — Realm**: Creates `waypoint-poc` realm.

**Step 2 — Three clients:**

| Client | Role | Secret |
|--------|------|--------|
| `echo-agent` | The agent. Users obtain tokens from this client via `client_credentials` grant. | `agent-secret` |
| `echo-tool` | The tool. Represents the target audience for exchanged tokens. Never called directly by users. | `tool-secret` |
| `token-exchange-service` | The shared ext_authz service. Authenticates to Keycloak to perform exchanges on behalf of agents. | `exchange-secret` |

**Step 3 — Enable standard token exchange** (`standard.token.exchange.enabled = "true"`):

Set on both `token-exchange-service` and `echo-tool`. This is a per-client attribute in Keycloak 26 that opts the client into the Standard Token Exchange V2 protocol. Without it, the exchange endpoint returns `"Client not allowed to exchange"`.

| Client | Why it needs the attribute |
|--------|--------------------------|
| `token-exchange-service` | It **calls** the exchange endpoint (it's the requesting client) |
| `echo-tool` | It's **targeted** as the audience (Keycloak must allow tokens to be scoped to it) |

`echo-agent` does NOT need this attribute — it never participates in the exchange call.

**Step 4 — Audience mappers** (control what goes into the `aud` claim of issued tokens):

| # | Mapper on client | Adds to `aud` | Why |
|---|-----------------|---------------|-----|
| 1 | `echo-agent` | `echo-agent` | Agent tokens include the agent's own name. This is how the ext_authz knows to pass through on inbound: `aud` includes the destination (`echo-agent`). |
| 2 | `echo-agent` | `token-exchange-service` | **Required by Keycloak.** When `token-exchange-service` presents the agent's token as `subject_token`, Keycloak checks that the requesting client (`token-exchange-service`) is in the subject token's `aud`. Without this mapper, the exchange fails. |
| 3 | `token-exchange-service` | `echo-tool` | When Keycloak issues the exchanged token, this mapper ensures `echo-tool` appears in the `aud` claim. This is how the tool knows the token is meant for it. |

**Step 5 — Verify**: The script obtains an agent token and performs a test exchange to confirm everything is wired correctly.

### Token lifecycle end-to-end

```
1. User authenticates:
   POST /token  client_id=echo-agent  client_secret=agent-secret
   grant_type=client_credentials

   → Keycloak returns:
     { aud: [echo-agent, token-exchange-service, account], azp: echo-agent, sub: <user-id> }
              ↑ mapper 1   ↑ mapper 2

2. User calls echo-agent with this token.

3. agent-waypoint intercepts (inbound):
   ext_authz: aud includes "echo-agent"? → YES → pass through

4. echo-agent forwards request to echo-tool.

5. tool-waypoint intercepts (outbound):
   ext_authz: aud includes "echo-tool"? → NO → exchange

6. ext_authz calls Keycloak:
   POST /token  grant_type=token-exchange
     subject_token = <agent token from step 1>
     audience = echo-tool
     client_id = token-exchange-service
     client_secret = exchange-secret

   Keycloak checks:
     ✓ token-exchange-service has standard.token.exchange.enabled
     ✓ subject_token is valid (signature, issuer, expiry)
     ✓ subject_token.aud includes token-exchange-service (mapper 2)
     ✓ echo-tool has standard.token.exchange.enabled

   → Keycloak returns:
     { aud: echo-tool, azp: token-exchange-service, sub: <same user-id> }
              ↑ mapper 3

7. ext_authz replaces Authorization header with the exchanged token.

8. echo-tool receives the request with aud=echo-tool.
```

### Issuer URL split

The token `iss` claim uses Keycloak's external hostname (e.g., `http://keycloak.localtest.me:8080`), which may differ from the in-cluster service URL (e.g., `http://keycloak-service.keycloak.svc:8080`). The token-exchange-service uses:
- `KEYCLOAK_URL` — internal service URL for JWKS fetch and token exchange API calls
- `ISSUER_URL` — external URL for JWT issuer validation (must match the `iss` claim in tokens)

## Prerequisites

A **kagenti cluster** already deployed locally, providing:

- **Kind cluster** named `kagenti` (override with `CLUSTER_NAME=<name>`)
- **Istio ambient mesh** with the `kagenti-token-exchange` ext_authz provider configured
- **Keycloak 26+** running in the `keycloak` namespace (service: `keycloak-service`)
- **`kagenti-system` namespace** for shared infrastructure

See the [kagenti repository](https://github.com/kagenti/kagenti) for cluster setup instructions.

## Quick Start

```bash
make up     # build + configure Keycloak + deploy
make test   # run E2E tests
make down   # remove everything (K8s resources + Keycloak realm)
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
| **Invalid token rejected** | Invalid token → agent-waypoint | ext_authz rejects (HTTP 401) before reaching agent |
| **Valid token exchanged** | Valid token → agent-waypoint → echo-agent → tool-waypoint | Token exchanged; echo-tool receives `aud=echo-tool`, `sub` preserved |

```bash
make test
```

## Known Constraints

1. **Waypoints are destination-side only** — Istio waypoints intercept traffic going TO services, not FROM. Outbound token exchange requires a waypoint in the tool namespace.
2. **CUSTOM action does not support `from.source.namespaces`** — Namespace filtering must use a separate ALLOW policy.
3. **One waypoint per tool namespace** — each tool namespace needs its own waypoint. Managed declaratively via namespace labels and AuthorizationPolicy CRs.
4. **No mTLS to Keycloak** — the token-exchange-service calls Keycloak over plain HTTP. Production should use TLS.
5. **In-memory cache** — token cache doesn't survive pod restarts. Production could use Redis.
6. **Convention: Keycloak client ID must match K8s service name** — the audience is derived from the hostname. If they differ, an override mechanism would be needed (not yet implemented).
7. **Convention doesn't work for external hostnames** — `api.github.com` → first segment is `api`, not a Keycloak client ID. External tools would need an explicit mapping.
8. **Issuer URL must be configured separately** — when Keycloak's external hostname differs from the internal service name.
