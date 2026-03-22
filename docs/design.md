# Design: Zero-Sidecar Token Exchange via Istio Waypoint

## Problem Statement

Kagenti's AuthBridge requires 5 containers per agent pod to perform token exchange:
1. Envoy sidecar (ext_proc filter)
2. go-processor (token exchange logic)
3. spiffe-helper (SPIFFE identity)
4. iptables init container (traffic redirection, requires NET_ADMIN)
5. client-registration init container

This adds ~150-200MB memory overhead per pod and requires privileged containers. For multi-tenant environments with many agent pods, this doesn't scale.

## Solution: Waypoint ext_authz

Istio ambient mesh introduces **waypoint proxies** — shared L7 proxies that handle policies for a namespace or service. By combining a waypoint with Envoy's `ext_authz` filter, we can:

1. Move token exchange logic to a **shared service** (1 instance per cluster, not per pod)
2. Eliminate all sidecar containers from agent/tool pods
3. Use declarative `AuthorizationPolicy` CRs instead of per-pod sidecar configuration

### Why ext_authz instead of ext_proc?

| | ext_authz | ext_proc |
|---|-----------|----------|
| Protocol | Unary gRPC (request/response) | Bidirectional gRPC stream |
| Complexity | Simple — one CheckRequest, one CheckResponse | Complex — multiple ProcessingRequest/Response per HTTP transaction |
| Header mutation | `OkHttpResponse.headers_to_set` | `HeaderMutation` in response to `request_headers` phase |
| Istio integration | Native via `AuthorizationPolicy CUSTOM` | Requires `EnvoyFilter` (not recommended for ambient) |
| Shared service | Natural — stateless, one call per request | Harder — stream lifetime tied to connection |

ext_authz is the right choice for this use case because:
- Token exchange is a unary operation (validate input token, return output token)
- Istio has first-class support via `AuthorizationPolicy` with `action: CUSTOM`
- The service is stateless and can be shared across all waypoints

### Why validate JWT in ext_authz instead of RequestAuthentication?

The plan considered using Istio's `RequestAuthentication` for JWT validation and ext_authz only for token exchange. We chose to do both in ext_authz because:

1. **Single point of logic**: Validation and exchange are tightly coupled — if validation fails, there's nothing to exchange. Having both in one service simplifies debugging.
2. **Meaningful error messages**: ext_authz can return detailed error responses (`{"error": "token expired"}`) vs RequestAuthentication's generic 401.
3. **No two-phase problem**: If RequestAuthentication validates the original token, and ext_authz replaces it, the waypoint would need to skip validation of the exchanged token. This creates a confusing policy chain.
4. **Matches AuthProxy model**: The existing AuthBridge go-processor handles both inbound validation and outbound exchange in one component.

## Waypoint Placement: Two Waypoints

Istio waypoints are **strictly destination-side** — they intercept traffic going TO services
in their namespace, never outbound FROM them. This was validated during the PoC: a waypoint
in agent-ns with `waypoint-for: workload` or `all` does not intercept outbound traffic
from the agent to tools in other namespaces.

Therefore the PoC uses **two waypoints** with a clear separation of concerns:

```
       agent-ns                                        tool-ns
┌────────────────────────┐                  ┌──────────────────────────┐
│                        │                  │                          │
│  agent-waypoint        │                  │  tool-waypoint           │
│  • inbound JWT         │                  │  • validate + exchange   │
│    validation          │                  │    outbound tokens       │
│                        │                  │                          │
│  Agent Pod ────────────┼── ztunnel mTLS ──┼──> Tool Pod              │
│  (1 container)         │                  │  (1 container)           │
└────────────────────────┘                  └──────────────────────────┘
```

| Waypoint | Namespace | waypoint-for | Responsibility |
|----------|-----------|-------------|----------------|
| agent-waypoint | agent-ns | all | Inbound JWT validation (reject bad tokens before they reach the agent) |
| tool-waypoint | tool-ns | service | Outbound token exchange (exchange agent token → tool-scoped token via RFC 8693) |

Both waypoints use the same shared `token-exchange-service` via ext_authz. The service
auto-distinguishes behavior based on the destination host: if an audience mapping exists
for the host, it exchanges; otherwise it validates and passes through.

## Istio Policy Chain

```
Inbound: User calls agent (agent-ns waypoint)
───────────────────────────────────────────────
User → agent-waypoint
            │
            ▼
  ┌─── CUSTOM (inbound-jwt-validation) ───┐
  │ targetRef: Gateway/agent-waypoint      │
  │ → ext_authz: validate JWT only         │
  │   (no audience mapping → pass through) │
  └───────────────┬───────────────────────┘
                  │
                  ▼
            Agent Pod


Outbound: Agent calls tool (tool-ns waypoint)
───────────────────────────────────────────────
Agent Pod → ztunnel (mTLS) → tool-waypoint
                                    │
                                    ▼
              ┌─── CUSTOM (outbound-token-exchange) ───┐
              │ targetRef: Gateway/tool-waypoint        │
              │ → ext_authz: validate JWT + exchange    │
              │ → replace Authorization header          │
              └───────────────┬────────────────────────┘
                              │
                              ▼
                        Tool Pod
```

## Token Exchange Flow (RFC 8693)

```
token-exchange-service                  Keycloak
        │                                  │
        │  POST /realms/waypoint-poc/      │
        │       protocol/openid-connect/   │
        │       token                      │
        │                                  │
        │  grant_type=                     │
        │    urn:ietf:params:oauth:        │
        │    grant-type:token-exchange     │
        │  subject_token=<agent-jwt>       │
        │  subject_token_type=             │
        │    urn:ietf:params:oauth:        │
        │    token-type:access_token       │
        │  audience=echo-tool              │
        │  client_id=token-exchange-service│
        │  client_secret=<secret>          │
        │─────────────────────────────────>│
        │                                  │
        │  { access_token: <tool-jwt>,     │
        │    expires_in: 300 }             │
        │<─────────────────────────────────│
```

The exchanged token has:
- `aud`: `echo-tool` (the target tool's client ID)
- `azp`: may differ based on Keycloak configuration
- `sub`: same as the original agent token's subject

## Caching Strategy

| Cache | Key | TTL | Purpose |
|-------|-----|-----|---------|
| Token cache | `hash(subject_token):audience` | `expires_in - 30s` | Avoid Keycloak round-trip on repeated calls |
| JWKS cache | N/A (background refresh) | 15 min refresh interval | Avoid JWKS endpoint calls on every validation |

The 30-second buffer before expiry prevents using tokens that are about to expire.

## Keycloak Configuration

### Standard Token Exchange V2 (No Feature Flags)

Keycloak 26 ships with **Standard Token Exchange V2** built-in. No server-level feature
flags (`--features=token-exchange,admin-fine-grained-authz`) are needed — this was validated
by running the E2E tests with Keycloak in production mode (`start`) with zero preview features.

Token exchange is configured per-client via two mechanisms:

1. **Enable standard token exchange** by setting the `standard.token.exchange.enabled`
   client attribute to `"true"` on:
   - The **requesting client** (`token-exchange-service`) — calls the token endpoint
   - The **target audience client** (`echo-tool`) — the audience the exchanged token is scoped to

2. **Add audience mappers** to control token routing:
   - `echo-agent` → audience mapper for `token-exchange-service` (so agent tokens include
     the exchange service in `aud` — required for subject token presentation)
   - `token-exchange-service` → audience mapper for `echo-tool` (so Keycloak allows
     exchanging tokens scoped to `echo-tool`)

No fine-grained admin permissions (FGAP), no client policies, no permission associations
are needed with this approach.

The `deploy/03-keycloak-setup.sh` script handles all of this: realm creation, client
registration, attribute patching, and audience mapper setup — all via the Keycloak admin REST API.

### Issuer URL Split

The token `iss` claim uses Keycloak's externally-configured hostname (e.g., `http://keycloak.localtest.me:8080`), which may differ from the in-cluster service URL (e.g., `http://keycloak-service.keycloak.svc:8080`). The token-exchange-service uses:
- `KEYCLOAK_URL` — internal service URL for JWKS fetch and token exchange API calls
- `ISSUER_URL` — external URL for JWT issuer validation (must match the `iss` claim)

## Limitations

1. **Waypoints are strictly destination-side**: Istio waypoints intercept traffic going TO services in their namespace, never outbound FROM them. This was validated during the PoC — a workload-level waypoint (`waypoint-for: workload` or `all`) in agent-ns does not see outbound calls to tools in other namespaces. This is why two waypoints are needed: agent-ns for inbound validation, tool-ns for token exchange.

2. **CUSTOM AuthorizationPolicy cannot filter by source namespace**: Istio validation rejects `from.source.namespaces` on CUSTOM actions. Namespace-based access control must be a separate ALLOW policy.

3. **One waypoint per tool namespace**: Each tool namespace needs its own waypoint with the ext_authz policy. In multi-namespace environments, this is managed declaratively via namespace labels and AuthorizationPolicy CRs.

4. **No mTLS to Keycloak**: The token-exchange-service calls Keycloak over plain HTTP within the cluster. Production should use TLS.

5. **Cache is in-memory**: Token cache doesn't survive pod restarts. Production could use Redis or similar.

6. **Host-to-audience mapping is static**: The `AUDIENCE_MAP` env var maps hostnames to Keycloak audiences. Production should use a ConfigMap or CRD.

7. **Issuer URL must be configured separately**: When Keycloak's external hostname differs from the internal service name, the token-exchange-service needs both `KEYCLOAK_URL` (for API calls) and `ISSUER_URL` (for JWT validation).
