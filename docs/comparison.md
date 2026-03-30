# Token Validation & Exchange: Approach Comparison

Comparison of three architectures for transparent JWT validation (inbound) and RFC 8693 token exchange (outbound) in Kubernetes agent-to-tool workflows.

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Repo** | [authbridge-waypoint](https://github.com/huang195/authbridge-waypoint) | [kagenti-extensions/AuthBridge](https://github.com/kagenti/kagenti-extensions) | [klaviger](https://github.com/grs/klaviger) |
| **Pattern** | Shared infrastructure (waypoint ext_authz or HTTP proxy) | Per-pod sidecar (Envoy + ext_proc + iptables) | Per-pod sidecar (Go binary, forward + reverse proxy) |

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
| **Per-pod privilege** | None | NET_ADMIN (blocked on EKS Fargate, GKE Autopilot) | None |
| **App change required** | None | None | `HTTP_PROXY` env var |
| **Infra per new destination** | Waypoint or egress GW + policy | None | None |
| **Failure domain** | Shared (all pods in namespace) | Per pod | Per pod |
| **Runs outside Kubernetes** | No | No | Yes |

## Developer Experience

AuthBridge uses an admission webhook to inject sidecars automatically, so the developer-facing YAML is similar to Waypoint. The differences are at runtime:

| | Waypoint | AuthBridge (with webhook) | Klaviger |
|---|---|---|---|
| **Developer writes** | Plain Deployment | Plain Deployment | Plain Deployment + `HTTP_PROXY` env |
| **What's injected at runtime** | Nothing | Sidecar + init container + secrets + ConfigMap | Sidecar + ConfigMap |
| **Containers running per pod** | 1 | 3 | 2 |
| **Extra infra to manage** | Waypoint (platform-managed) | Webhook + SPIFFE (platform-managed) | Per-pod config |

## Credential Isolation

Token exchange requires a client secret to authenticate to Keycloak. Where that secret lives determines the blast radius of a compromised pod.

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Exchange credentials location** | Shared ext_authz pod in `kagenti-system` | Every app pod (Secret mount or `/shared/` file) | Every app pod (config file or env var) |
| **App pod has access to exchange secret** | No | Yes | Yes |
| **Compromised app can steal exchange credentials** | No | Yes | Yes |

## Resource Cost (5000 pods, 20 namespaces)

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Per-pod sidecar** | None | Envoy + ext_proc | Go binary |
| **Per-pod memory** | 0 | ~200Mi | ~64Mi |
| **Shared infra** | 20 waypoints + 1 ext_authz | None | None |
| **Total added memory** | **~5Gi** | **~1Ti** | **~320Gi** |

## Day 2 Operations

With per-pod sidecars, updating auth logic requires a fleet-wide rolling restart. With shared infrastructure, it's a single deployment.

| | Waypoint | AuthBridge | Klaviger |
|---|---|---|---|
| **Patch token exchange logic** | 1 Deployment rollout | Rolling restart of every pod | Rolling restart of every pod |
| **Rotate exchange credentials** | 1 Secret update | Update Secret in every namespace | Update config in every namespace |
| **Patch auth vulnerability** | 1 image update, seconds | New sidecar image, rolling restart 5000 pods | New sidecar image, rolling restart 5000 pods |
