# Token Validation & Exchange: Approach Comparison

Comparison of three architectures for transparent JWT validation (inbound) and RFC 8693 token exchange (outbound) in Kubernetes agent-to-tool workflows.

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Repo** | [authbridge-waypoint](https://github.com/huang195/authbridge-waypoint) | [kagenti-extensions/AuthBridge](https://github.com/kagenti/kagenti-extensions) | [klaviger](https://github.com/grs/klaviger) |
| **Pattern** | Shared infrastructure (Istio waypoint + ext_authz) | Per-pod sidecar (Envoy + ext_proc + iptables) | Per-pod sidecar (Go binary, forward + reverse proxy) |

## Hard Constraints

These are architectural limitations that cannot be resolved by adding more code.

### Outbound Token Exchange Coverage

Inbound validation has no hard gaps for any approach. Outbound is where they diverge:

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Intercepts outbound via** | Waypoint in destination namespace | iptables OUTPUT redirect | App sets `HTTP_PROXY` |
| **In-cluster HTTP** | Full | Full | Proxy-aware clients only |
| **External HTTP** | Requires egress gateway | Full | Proxy-aware clients only |
| **HTTPS** | **No** | **No** | **No** |
| **Hard gap** | Infra needed per destination | None for HTTP | gRPC, DB drivers, non-proxy-aware clients skip exchange entirely |

All three face the same fundamental TLS limitation: token exchange cannot be performed on HTTPS outbound traffic without TLS termination. For HTTPS destinations, the application must set the Authorization header itself. Waypoint has a partial workaround via egress gateway (infrastructure-managed TLS termination), which the other two do not.

### Platform & Operational Constraints

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Platform lock-in** | Istio ambient mesh | None | None |
| **Per-pod privilege** | None | NET_ADMIN | None |
| **App change required** | None | None | `HTTP_PROXY` env var |
| **Outbound coverage** | Full (with infra per destination) | Full | Partial |
| **Infra per new destination** | Waypoint or egress GW + policy | None | None |
| **Failure domain** | Shared (all pods in namespace) | Per pod | Per pod |
| **Runs outside Kubernetes** | No | No | Yes |

## Developer Experience

AuthBridge uses an admission webhook to inject sidecars automatically, so the developer-facing YAML is similar to Waypoint. The differences are at runtime:

| | Waypoint | AuthBridge (with webhook) | Klaviger |
|---|---|---|---|
| **Developer writes** | Plain Deployment | Plain Deployment | Plain Deployment + `HTTP_PROXY` env |
| **What's injected** | Nothing | Sidecar + init container + secrets + ConfigMap | Sidecar + ConfigMap |
| **NET_ADMIN at runtime** | No | Yes (init container) | No |
| **Containers running per pod** | 1 | 3 | 2 |
| **Extra infra to manage** | Waypoint (platform-managed) | Webhook + SPIFFE (platform-managed) | Per-pod config |
| **Blocked on restricted clusters** | No | Yes (NET_ADMIN) | No |

## Resource Cost (5000 pods, 20 namespaces)

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Per-pod sidecar** | None | Envoy + ext_proc | Go binary |
| **Per-pod memory** | 0 | ~200Mi | ~64Mi |
| **Shared infra** | 20 waypoints + 1 ext_authz | None | None |
| **Total added memory** | **~5Gi** | **~1Ti** | **~320Gi** |
