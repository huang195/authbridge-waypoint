# Token Validation & Exchange: Approach Comparison

Comparison of four architectures for transparent JWT validation (inbound) and RFC 8693 token exchange (outbound) in Kubernetes agent-to-tool workflows.

## At a Glance

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **How it works** | Agent pods set `HTTP_PROXY` pointing to a shared token-exchange-service. No mesh, no sidecar. | Istio waypoint calls a shared token-exchange-service via ext_authz. No sidecar. | Per-pod Envoy sidecar + go-processor + iptables intercept all traffic. | Per-pod Go binary acts as forward + reverse proxy via `HTTP_PROXY`. |
| **Containers per pod** | **1** | **1** | 3 | 2 |
| **Per-pod memory overhead** | **0** | **0** | ~200Mi | ~64Mi |
| **Requires NET_ADMIN** | **No** | **No** | Yes | No |
| **Requires service mesh** | **No** | Yes (Istio ambient) | No | No |
| **Exchange credentials in pod** | **No** | **No** | Yes | Yes |
| **Patch exchange logic** | **1 rollout** | **1 rollout** | Restart all pods | Restart all pods |
| **Pattern** | Shared HTTP proxy | Shared ext_authz on waypoint | Per-pod sidecar | Per-pod sidecar |

The Shared Proxy and Waypoint approaches use the **same backend service** — one codebase, two interfaces. Start with Shared Proxy (no mesh dependency), migrate to Waypoint when ambient mesh is adopted.

---

## Credential Isolation

Token exchange requires a client secret to authenticate to Keycloak. Where that secret lives determines the blast radius of a compromised pod.

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Exchange credentials location** | Shared proxy pod in `kagenti-system` | Shared ext_authz pod in `kagenti-system` | Every app pod (Secret mount or `/shared/` file) | Every app pod (config file or env var) |
| **App pod has access to exchange secret** | No | No | Yes | Yes |
| **Compromised app can steal exchange credentials** | No | No | Yes | Yes |

---

## Resource Cost (5000 pods, 20 namespaces)

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Per-pod sidecar** | None | None | Envoy + ext_proc | Go binary |
| **Per-pod memory** | 0 | 0 | ~200Mi | ~64Mi |
| **Shared infra** | 1 proxy service | 20 waypoints + 1 ext_authz | None | None |
| **Total added memory** | **~128Mi** | **~5Gi** | **~1Ti** | **~320Gi** |

---

## Day 2 Operations

With per-pod sidecars, updating auth logic requires a fleet-wide rolling restart. With shared infrastructure, it's a single deployment.

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Patch token exchange logic** | 1 Deployment rollout | 1 Deployment rollout | Rolling restart of every pod | Rolling restart of every pod |
| **Rotate exchange credentials** | 1 Secret update | 1 Secret update | Update Secret in every namespace | Update config in every namespace |
| **Patch auth vulnerability** | 1 image update, seconds | 1 image update, seconds | New sidecar image, rolling restart 5000 pods | New sidecar image, rolling restart 5000 pods |

---

## Outbound Token Exchange Coverage

Inbound validation has no hard gaps for any approach. Outbound is where they diverge:

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Intercepts outbound via** | App sets `HTTP_PROXY` | Waypoint in destination namespace | iptables OUTPUT redirect | App sets `HTTP_PROXY` |
| **In-cluster HTTP** | Proxy-aware clients only | Full | Full | Proxy-aware clients only |
| **External HTTP** | Proxy-aware clients only | Requires egress gateway | Full | Proxy-aware clients only |
| **HTTPS** | **No** | **No** | **No** | **No** |
| **Hard gap** | gRPC, non-proxy-aware clients skip exchange | Infra needed per destination namespace | None for HTTP | gRPC, non-proxy-aware clients skip exchange |

All four face the same fundamental TLS limitation: token exchange cannot be performed on HTTPS outbound traffic without TLS termination. For HTTPS destinations, the application must set the Authorization header itself.

---

## Platform & Operational Constraints

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Platform lock-in** | None | Istio ambient mesh | None | None |
| **Per-pod privilege** | None | None | NET_ADMIN (blocked on EKS Fargate, GKE Autopilot) | None |
| **App change required** | `HTTP_PROXY` env var (via webhook) | None | None | `HTTP_PROXY` env var |
| **Infra per new destination** | None | Waypoint or egress GW + policy | None | None |
| **Failure domain** | Shared (single proxy service) | Shared (all pods in namespace) | Per pod | Per pod |
| **Runs outside Kubernetes** | No | No | No | Yes |

---

## Developer Experience

| | Shared Proxy | Waypoint | AuthBridge (with webhook) | Klaviger |
|---|---|---|---|---|
| **Developer writes** | Plain Deployment | Plain Deployment | Plain Deployment | Plain Deployment + `HTTP_PROXY` env |
| **What's injected at runtime** | `HTTP_PROXY` env var (via webhook) | Nothing | Sidecar + init container + secrets + ConfigMap | Sidecar + ConfigMap |
| **Containers running per pod** | 1 | 1 | 3 | 2 |
| **Extra infra to manage** | Shared proxy (platform-managed) | Waypoint (platform-managed) | Webhook + SPIFFE (platform-managed) | Per-pod config |

---

## Migration Path

The Shared Proxy and Waypoint approaches use the same token-exchange-service backend. Migration between them is zero-disruption:

| Step | What changes | What stays the same |
|---|---|---|
| **Start with Shared Proxy** | `HTTP_PROXY` env var on agent pods | Token exchange logic, Keycloak config, caching |
| **Adopt ambient mesh** | Enable Istio ambient on namespaces, add waypoint + AuthorizationPolicy | Token exchange service (same pod, same config) |
| **Switch to Waypoint** | Remove `HTTP_PROXY` env var | Everything else — the waypoint ext_authz calls the same service |

Both modes can coexist in the same cluster for gradual migration.

---

## Repos

| | Shared Proxy | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|---|
| **Repo** | [authbridge-waypoint](https://github.com/huang195/authbridge-waypoint) | [authbridge-waypoint](https://github.com/huang195/authbridge-waypoint) | [kagenti-extensions/AuthBridge](https://github.com/kagenti/kagenti-extensions) | [klaviger](https://github.com/grs/klaviger) |
