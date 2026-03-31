# Zero-Sidecar Agent Access Control via Shared Token Exchange Service

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using a shared token-exchange-service for RFC 8693 token exchange. Two modes, same backend:

- **Waypoint mode** (Istio ambient mesh) — ext_authz filter on the waypoint, no pod-level changes
- **HTTP proxy mode** (no mesh required) — `HTTP_PROXY` env var on agent pods, no sidecar, no NET_ADMIN

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
       agent-ns                                    tool-ns
┌─────────────────────┐       ┌───────────────────────────────────────┐
│                     │       │                                       │
│  Agent Pod          │       │  tool-waypoint (L7)                   │
│  (1 container)      │──────>│  │                                    │
│                     │       │  ├─ ext_authz                         │
│  agent-waypoint(L7) │       │  │  aud missing destination           │
│  │                  │       │  │  → exchange via RFC 8693            │
│  ├─ ext_authz       │       │  │                                    │
│  │  aud has         │       │  ▼                                    │
│  │  "demo-agent"    │       │  ┌─────────────┐  ┌─────────────┐    │
│  │  → pass through  │       │  │ echo-tool   │  │ time-tool   │    │
│  ▼                  │       │  │ (1 ctr)     │  │ (1 ctr)     │    │
└─────────────────────┘       │  └─────────────┘  └─────────────┘    │
                              │                                       │
                              └───────────────────────────────────────┘
```

**Two waypoints, one shared ext_authz service, zero per-tool config:**

- **agent-waypoint** (agent-ns) — token `aud` includes destination → pass through
- **tool-waypoint** (tool-ns) — token `aud` missing destination → exchange via RFC 8693

Both tools share the same waypoint and policy. Adding a tool requires only a Keycloak client and a Deployment — no new waypoint, policy, or namespace.

The service derives the destination audience from the hostname (convention: K8s service name = first segment of FQDN). No audience maps or direction config needed — the token's `aud` claim is the signal.

**Token flow (same for any tool):**

1. User calls `demo-agent` with a JWT (`aud` includes `demo-agent`)
2. agent-waypoint: ext_authz validates JWT, `aud` includes `demo-agent` → pass through
3. `demo-agent` forwards the request to a tool (`echo-tool` or `time-tool`)
4. tool waypoint: ext_authz validates JWT, `aud` missing tool name → exchange
   - Calls Keycloak RFC 8693 token exchange
   - Replaces `Authorization` header with tool-scoped token
5. Tool receives the exchanged token (`aud=<tool-name>`, `sub` preserved)

Adding a new tool to an existing namespace requires only: 1 Keycloak client + audience mapper, 1 Deployment. No changes to the agent, token-exchange-service, waypoint, policy, or existing tools.

## What This Proves

| Property | AuthBridge (current) | Waypoint PoC |
|----------|---------------------|--------------|
| Containers per agent pod | 5 (envoy, go-processor, spiffe-helper, 2 init) | 1 |
| Memory overhead per pod | ~150-200MB | 0 (shared waypoints) |
| NET_ADMIN / iptables | Required | Not needed |
| HTTP_PROXY env vars | Required | Optional (HTTP proxy mode) or not needed (waypoint mode) |
| Token exchange | Per-pod sidecar | Shared service (ext_authz or HTTP proxy) |
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
- Requests without an Authorization header are allowed only on bypass paths (`/.well-known/*`, `/healthz`, `/readyz`, `/livez`). All other unauthenticated requests are rejected. Override via `BYPASS_INBOUND_PATHS` env var (comma-separated, same pattern as AuthBridge).
- No two-phase problem — the waypoint doesn't need to skip validation of the exchanged token

## Waypoint Placement

Istio waypoints are **strictly destination-side** — they intercept traffic going TO services in their namespace, never outbound FROM them. This was validated during the PoC: a workload-level waypoint (`waypoint-for: workload` or `all`) in agent-ns does not see outbound calls to tools in other namespaces.

| Waypoint | Namespace | waypoint-for | Responsibility |
|----------|-----------|-------------|----------------|
| agent-waypoint | agent-ns | all | `aud` includes destination → pass through |
| tool-waypoint | tool-ns | service | `aud` missing destination → exchange (covers all tools in tool-ns) |

**Istio policy chain:**

```
Inbound: User → agent-waypoint → Agent Pod
                    │
                    └─ ext_authz: validate JWT, check aud
                       aud includes "demo-agent" → pass through

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
GET /realms/kagenti/protocol/openid-connect/certs
→ Returns the realm's RSA public keys for JWT signature verification
```
The service caches these keys and uses them to validate every incoming JWT without calling Keycloak per-request.

**2. Token exchange** (per-request, when `aud` is missing the destination):
```
POST /realms/kagenti/protocol/openid-connect/token

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

When the token exchange request arrives, Keycloak validates three things:

```
1. Is token-exchange-service allowed to call the exchange endpoint?
   → Check: standard.token.exchange.enabled = "true" on token-exchange-service
   → Without this: "Client not allowed to exchange"

2. Is the subject_token valid?
   → Check: signature, issuer, expiry (same as any JWT validation)

3. Is token-exchange-service in the subject_token's audience?
   → Check: subject_token.aud includes "token-exchange-service"
   → Without this: "Client not allowed to exchange: not in subject token audience"
   → This is why demo-agent needs the token-exchange-service audience mapper
```

The exchanged token has:
- `aud`: `echo-tool` (the target tool's client ID)
- `azp`: `token-exchange-service` (the client that performed the exchange)
- `sub`: same as the original agent token's subject (preserved through exchange)

### Setup (deploy/03-keycloak-setup.sh)

The setup script configures Keycloak via the admin REST API. Here's what it creates and why:

**Step 1 — Realm**: Uses the existing `kagenti` realm (shared with the kagenti platform). Creates it if not present.

**Step 2 — Four clients:**

| Client | Role | Secret |
|--------|------|--------|
| `demo-agent` | The agent. Users obtain tokens from this client via `client_credentials` grant. | `agent-secret` |
| `echo-tool` | A tool. Represents the target audience for exchanged tokens. | `tool-secret` |
| `time-tool` | A tool. Second tool for multi-tool demo. | `time-tool-secret` |
| `token-exchange-service` | The shared ext_authz service. Authenticates to Keycloak to perform exchanges on behalf of agents. | `exchange-secret` |

**Step 3 — Enable standard token exchange** (`standard.token.exchange.enabled = "true"`):

Set on `token-exchange-service` only. This is a per-client attribute in Keycloak 26 that allows the client to call the token exchange endpoint. Without it, Keycloak returns `"Client not allowed to exchange"`.

Only the **requesting client** needs this attribute. The target audience client (`echo-tool`) and the token owner (`demo-agent`) do not.

**Step 4 — Audience mappers** (control what goes into the `aud` claim of issued tokens):

| # | Mapper on client | Adds to `aud` | Why |
|---|-----------------|---------------|-----|
| 1 | `demo-agent` | `demo-agent` | Agent tokens include the agent's own name. This is how the ext_authz knows to pass through on inbound: `aud` includes the destination (`demo-agent`). |
| 2 | `demo-agent` | `token-exchange-service` | **Required by Keycloak.** When `token-exchange-service` presents the agent's token as `subject_token`, Keycloak checks that the requesting client (`token-exchange-service`) is in the subject token's `aud`. Without this mapper, the exchange fails. |
| 3 | `token-exchange-service` | `echo-tool` | When Keycloak issues the exchanged token, this mapper ensures `echo-tool` appears in the `aud` claim. |
| 4 | `token-exchange-service` | `time-tool` | Same as above for the second tool. Each new tool needs one audience mapper on `token-exchange-service`. |
| 5 | `kagenti` (platform) | `token-exchange-service` | Allows the kagenti platform (UI/backend) tokens to be exchanged by the ext_authz. Same role as mapper 2, but for the platform client. |

**Step 5 — Verify**: The script obtains an agent token and performs a test exchange to confirm everything is wired correctly.

### Token lifecycle end-to-end

```
1. User authenticates:
   POST /token  client_id=demo-agent  client_secret=agent-secret
   grant_type=client_credentials

   → Keycloak returns:
     { aud: [demo-agent, token-exchange-service, account], azp: demo-agent, sub: <user-id> }
              ↑ mapper 1   ↑ mapper 2

2. User calls demo-agent with this token.

3. agent-waypoint intercepts (inbound):
   ext_authz: aud includes "demo-agent"? → YES → pass through

4. demo-agent forwards request to echo-tool.

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
make down   # remove K8s resources + Keycloak clients (realm is shared)
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| `demo-agent` | `cmd/demo-agent/` | Receives a user token, forwards it to echo-tool or time-tool |
| `echo-tool` | `cmd/echo-tool/` | Echoes request headers as JSON — verifies the exchanged token |
| `time-tool` | `cmd/time-tool/` | Returns current time + JWT claims — second tool for multi-tool demo |
| `token-exchange-service` | `cmd/token-exchange-service/` | Shared service: JWT validation + RFC 8693 token exchange. Dual interface: gRPC ext_authz (waypoint) + HTTP forward proxy (HTTP_PROXY) |

## Demo Scripts

| Script | Description |
|--------|-------------|
| `deploy/10-add-tool-demo.sh` | Interactive demo: add a new tool (weather-tool) with zero infra changes |
| `deploy/11-weather-agent-demo.sh` | Deploy real kagenti weather agent + tool with waypoint security |

## End-to-End Tests

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | Invalid token → agent-waypoint | ext_authz rejects (HTTP 401) before reaching agent |
| **Valid token → echo-tool** | Valid token → demo-agent → tool-waypoint | Token exchanged; echo-tool receives `aud=echo-tool`, `sub` preserved |
| **Valid token → time-tool** | Valid token → demo-agent → tool-waypoint | Token exchanged; time-tool receives `aud=time-tool`, `sub` preserved |
| **HTTP proxy mode** | Valid token → demo-agent → echo-tool (no mesh, via `HTTP_PROXY`) | Token exchanged via HTTP proxy; same result as waypoint mode |

```bash
make test
```

## Troubleshooting

### Waypoint tests fail but HTTP proxy tests pass

**Symptom:** Tests 1-3 (waypoint/ext_authz path) fail with empty responses, while Test 4 (HTTP proxy mode) passes. The waypoint logs show only XDS reconnections with no application traffic.

**Cause:** Expired mTLS certificates in the Istio ambient mesh. The ztunnel logs will show:

```
error  h2 failed: received fatal alert: CertificateExpired
```

This happens when the waypoint pods and ztunnel have been running long enough for their workload certificates to expire without automatic renewal (e.g., if istiod was restarted or the cluster was suspended).

**Fix:** Restart the waypoints and ztunnel to force certificate renewal:

```bash
kubectl rollout restart deployment -n agent-ns agent-waypoint
kubectl rollout restart deployment -n tool-ns tool-waypoint
kubectl rollout restart daemonset -n istio-system ztunnel
```

**Diagnosis:** Check ztunnel logs for certificate errors:

```bash
kubectl logs -n istio-system -l app=ztunnel | grep -i "CertificateExpired"
```

### Token exchange returns empty response

If `tool_status` is empty in the test output, the request likely never reached `demo-agent`. Check:

1. **Waypoint is programmed:** `kubectl get gtw -n agent-ns` should show `PROGRAMMED=True`
2. **Namespace labels are correct:** `kubectl get ns agent-ns -o jsonpath='{.metadata.labels}'` should include `istio.io/dataplane-mode: ambient` and `istio.io/use-waypoint: agent-waypoint`
3. **ext_authz service is running:** `kubectl get pods -n kagenti-system -l app=token-exchange-service`

### Keycloak token acquisition fails

If the test script can't obtain a token from Keycloak:

1. **Port-forward conflict:** Kill stale port-forwards: `lsof -ti tcp:18080 | xargs kill`
2. **Keycloak not ready:** `kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=60s`
3. **Client misconfigured:** Re-run `make up` to reconfigure Keycloak clients

## Known Constraints

1. **Waypoints are destination-side only** — Istio waypoints intercept traffic going TO services, not FROM. Outbound token exchange requires a waypoint in the tool namespace.
2. **CUSTOM action does not support `from.source.namespaces`** — Namespace filtering must use a separate ALLOW policy.
3. **One waypoint per tool namespace** — each tool namespace needs its own waypoint, but all tools within the namespace share it. Managed declaratively via namespace labels and AuthorizationPolicy CRs.
4. **No mTLS to Keycloak** — the token-exchange-service calls Keycloak over plain HTTP. Production should use TLS.
5. **In-memory cache** — token cache doesn't survive pod restarts. Production could use Redis.
6. **Convention: Keycloak client ID must match K8s service name** — the audience is derived from the hostname. If they differ, an override mechanism would be needed (not yet implemented).
7. **Convention doesn't work for external hostnames** — `api.github.com` → first segment is `api`, not a Keycloak client ID. External tools would need an explicit mapping.
8. **Issuer URL must be configured separately** — when Keycloak's external hostname differs from the internal service name.
