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
- `azp`: `token-exchange-service` (the client that performed the exchange)
- `sub`: same as the original agent token's subject (preserved through exchange)

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

## External Tools via Egress Gateway

When a tool lives outside the cluster (e.g., `api.github.com`), the same ext_authz
mechanism works via the Istio **egress gateway**. The egress gateway sits on the path
for traffic leaving the cluster and can trigger ext_authz to exchange tokens before
the request reaches the external service.

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate agent JWT,
                            exchange for tool-scoped token,
                            replace Authorization header
```

A `ServiceEntry` defines the external tool, and an `AuthorizationPolicy CUSTOM` on the
egress gateway triggers the same `token-exchange-service`. The `AUDIENCE_MAP` just needs
entries for external hosts (e.g., `api.github.com=github-tool`).

This gives a unified model — one token-exchange-service handles all destinations:

| Destination | Interception point | ext_authz |
|---|---|---|
| In-cluster tool (different namespace) | tool-ns waypoint | Same service |
| In-cluster tool (same namespace) | namespace waypoint | Same service |
| External tool | egress gateway | Same service |

## Alternative Approaches

The mesh + ext_authz approach (this PoC) is one of three distinct strategies for
agent-to-tool token exchange. Each optimizes for a different constraint.

### Approach 1: Mesh + ext_authz (this PoC)

Waypoints (Istio ambient) or Cilium L7 policy intercept traffic and call a shared
ext_authz service for token exchange. Works with any mesh that supports Envoy ext_authz.

- **Agent code changes**: None
- **Infrastructure**: Mesh + ext_authz service + per-namespace policies
- **Onboarding a new tool**: Add namespace label + audience mapping
- **Failure blast radius**: ext_authz down → all agents blocked
- **Debugging**: Waypoint logs + ext_authz logs + Keycloak logs (3 systems)
- **External tools**: Yes, via egress gateway

**Best when**: A service mesh is already present. Agents get transparent token exchange
with zero code changes — the mesh handles it as infrastructure.

### Approach 2: SDK / library

Embed token exchange in the agent framework SDK. The agent calls a library function
before making tool requests. No infrastructure required.

- **Agent code changes**: Import library + call before tool requests
- **Infrastructure**: None
- **Onboarding a new tool**: Nothing (SDK handles it via config)
- **Failure blast radius**: Library bug → that agent only
- **Debugging**: Application logs (1 system)
- **External tools**: Yes, natively

**Best when**: No assumptions about the target environment. Works on any platform
(Kubernetes, VMs, local dev). Most portable option.

### Approach 3: K8s SA token projection + OIDC federation

Project a Kubernetes ServiceAccount token with `audience: echo-tool`. Keycloak trusts
the K8s API server as an OIDC issuer. No runtime token exchange at all — Kubernetes
issues the right token at pod scheduling time.

- **Agent code changes**: Mount projected volume, read token from file
- **Infrastructure**: Keycloak OIDC federation per cluster
- **Onboarding a new tool**: Add audience to SA token projection + Keycloak trust
- **Failure blast radius**: Misconfigured projection → that pod only
- **Debugging**: `kubectl describe pod` (1 system)
- **External tools**: Yes, if external tool trusts K8s-issued tokens

**Best when**: Token exchange can be eliminated entirely. Simplest security model,
but requires Keycloak OIDC federation setup per cluster and couples token issuance
to pod scheduling.

### Recommendation

No single approach is a clear winner — each fits a different deployment model:

| Priority | Best fit |
|----------|----------|
| Zero agent code changes, mesh already present | Mesh + ext_authz |
| Zero infrastructure, works anywhere | SDK / library |
| Zero runtime token exchange, simplest model | SA token projection |

For Kagenti, **SDK/library** is the strongest default (works everywhere, no infra
dependencies), and **mesh + ext_authz** is the best upgrade path when a mesh is present —
the SDK can detect the mesh and skip the exchange, letting the waypoint handle it
transparently.

## External Tools via Egress Gateway

When a tool lives outside the cluster (e.g., `api.github.com`), the same ext_authz
mechanism works via the Istio **egress gateway**. The egress gateway sits on the path
for traffic leaving the cluster and can trigger ext_authz to exchange tokens before
the request reaches the external service.

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate agent JWT,
                            exchange for tool-scoped token,
                            replace Authorization header
```

A `ServiceEntry` defines the external tool, and an `AuthorizationPolicy CUSTOM` on the
egress gateway triggers the same `token-exchange-service`. The `AUDIENCE_MAP` just needs
entries for external hosts (e.g., `api.github.com=github-tool`).

This gives a unified model — one token-exchange-service handles all destinations:

| Destination | Interception point | ext_authz |
|---|---|---|
| In-cluster tool (different namespace) | tool-ns waypoint | Same service |
| In-cluster tool (same namespace) | namespace waypoint | Same service |
| External tool | egress gateway | Same service |

## Limitations

1. **Waypoints are strictly destination-side**: Istio waypoints intercept traffic going TO services in their namespace, never outbound FROM them. This was validated during the PoC — a workload-level waypoint (`waypoint-for: workload` or `all`) in agent-ns does not see outbound calls to tools in other namespaces. This is why two waypoints are needed: agent-ns for inbound validation, tool-ns for token exchange.

2. **CUSTOM AuthorizationPolicy cannot filter by source namespace**: Istio validation rejects `from.source.namespaces` on CUSTOM actions. Namespace-based access control must be a separate ALLOW policy.

3. **One waypoint per tool namespace**: Each tool namespace needs its own waypoint with the ext_authz policy. In multi-namespace environments, this is managed declaratively via namespace labels and AuthorizationPolicy CRs.

4. **No mTLS to Keycloak**: The token-exchange-service calls Keycloak over plain HTTP within the cluster. Production should use TLS.

5. **Cache is in-memory**: Token cache doesn't survive pod restarts. Production could use Redis or similar.

6. **Host-to-audience mapping is static**: The `AUDIENCE_MAP` env var maps hostnames to Keycloak audiences. Production should use a ConfigMap or CRD.

7. **Issuer URL must be configured separately**: When Keycloak's external hostname differs from the internal service name, the token-exchange-service needs both `KEYCLOAK_URL` (for API calls) and `ISSUER_URL` (for JWT validation).
