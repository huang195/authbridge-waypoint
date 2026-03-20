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

## Istio Policy Chain

```
Request arrives at waypoint
        │
        ▼
┌─── CUSTOM ───┐     Calls token-exchange-service via ext_authz.
│ token-exchange│     Validates JWT, exchanges token, sets new Authorization header.
│               │     NOTE: CUSTOM does not support from.source.namespaces —
└───────┬───────┘     matches all requests; namespace filtering is in ALLOW.
        │
        ▼
┌─── DENY ─────┐     (None configured — would go here if needed)
└───────┬───────┘
        │
        ▼
┌─── ALLOW ────┐     allow-agent-to-tool: only agent-ns sources allowed.
│ namespace    │     Uses mTLS identity (ztunnel provides SPIFFE ID).
│ check        │     Defense-in-depth: even if ext_authz is misconfigured,
└───────┬───────┘     only agent-ns pods can reach the tool.
        │
        ▼
  Forward to backend (echo-tool) with exchanged token
```

**Important**: Istio's CUSTOM action does not support `from.source.namespaces` or other
L4 source matchers. The CUSTOM policy must use `rules: [{}]` (match all) and rely on
the separate ALLOW policy for namespace-based access control.

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

### Required Features

Keycloak 26 requires two preview features enabled via CLI args:

```
--features=token-exchange,admin-fine-grained-authz:v1
```

- **`token-exchange`**: Enables the RFC 8693 `urn:ietf:params:oauth:grant-type:token-exchange` grant type
- **`admin-fine-grained-authz:v1`**: Enables per-client management permissions (the `/management/permissions` API), which is required to grant token-exchange rights to specific clients

**Critical**: The `:v1` version suffix on `admin-fine-grained-authz` is mandatory. Without it, Keycloak 26 silently ignores the feature. This is not documented in the Keycloak admin guide.

### Token Exchange Permission

Keycloak requires explicit permission for token exchange. Three steps are needed after realm/client creation:

1. **Enable fine-grained permissions on the target client** (echo-tool):
   ```
   PUT /admin/realms/{realm}/clients/{echo-tool-uuid}/management/permissions
   {"enabled": true}
   ```
   This auto-creates a `token-exchange` scope permission.

2. **Create a client policy** matching the exchange service:
   ```
   POST /admin/realms/{realm}/clients/{realm-management-uuid}/authz/resource-server/policy/client
   {"name": "allow-token-exchange-service", "clients": ["{exchange-client-uuid}"], "logic": "POSITIVE"}
   ```

3. **Associate the policy** with the auto-created token-exchange permission:
   ```
   PUT /admin/realms/{realm}/clients/{realm-management-uuid}/authz/resource-server/permission/scope/{perm-id}
   {...existing fields, "policies": ["{policy-id}"]}
   ```

The realm JSON import creates clients but cannot configure these permissions (they require the admin REST API). The `deploy/03-keycloak-setup.sh` script handles this post-import setup.

### Issuer URL Split

The token `iss` claim uses Keycloak's externally-configured hostname (e.g., `http://keycloak.localtest.me:8080`), which may differ from the in-cluster service URL (e.g., `http://keycloak-service.keycloak.svc:8080`). The token-exchange-service uses:
- `KEYCLOAK_URL` — internal service URL for JWKS fetch and token exchange API calls
- `ISSUER_URL` — external URL for JWT issuer validation (must match the `iss` claim)

## Limitations

1. **Keycloak token exchange setup**: The realm JSON import creates clients but the token-exchange permission requires post-import admin API calls (enable fine-grained permissions on target client, create client policy, associate with permission). This cannot be done via realm import alone.

2. **CUSTOM AuthorizationPolicy cannot filter by source namespace**: Istio validation rejects `from.source.namespaces` on CUSTOM actions. Namespace-based access control must be a separate ALLOW policy, making the policy chain two resources instead of one.

3. **Single waypoint per namespace**: The waypoint is scoped to `tool-ns`. Multi-namespace routing would need waypoints per namespace or a service-level waypoint attachment.

4. **No mTLS to Keycloak**: The token-exchange-service calls Keycloak over plain HTTP within the cluster. Production should use TLS.

5. **Cache is in-memory**: Token cache doesn't survive pod restarts. Production could use Redis or similar.

6. **Host-to-audience mapping is static**: The `AUDIENCE_MAP` env var maps hostnames to Keycloak audiences. Production should use a ConfigMap or CRD.

7. **Issuer URL must be configured separately**: When Keycloak's external hostname differs from the internal service name, the token-exchange-service needs both `KEYCLOAK_URL` (for API calls) and `ISSUER_URL` (for JWT validation). This is common in Kubernetes where ingress hostnames differ from service DNS.
