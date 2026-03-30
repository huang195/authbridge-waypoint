#!/usr/bin/env bash
# End-to-end tests for the waypoint token exchange PoC.
#
# Test architecture (two waypoints, multiple tools):
#
#   User (curl pod, agent-ns)
#     │
#     │  Authorization: Bearer <user-token>
#     ▼
#   agent-waypoint (agent-ns) ── inbound JWT validation
#     │
#     ▼
#   demo-agent (agent-ns)
#     │
#     ├─ /call/echo-tool → echo-tool.tool-ns  (forwards user token)
#     ├─ /call/time-tool → time-tool.tool-ns  (forwards user token)
#     ▼
#   ztunnel (L4 mTLS)
#     │
#     ▼
#   tool-waypoint (tool-ns) ── outbound token exchange
#     │
#     ├─ ext_authz: validate JWT + exchange via RFC 8693
#     │  replace Authorization header (aud=<tool-name>)
#     ▼
#   echo-tool / time-tool (tool-ns, same waypoint)
#
# Tests:
#   1. Invalid token → agent-waypoint rejects (ext_authz denies before reaching agent)
#   2. Valid token → echo-tool: waypoint exchanges → aud=echo-tool
#   3. Valid token → time-tool: same waypoint exchanges → aud=time-tool
#   4. Full E2E via HTTP_PROXY (no ambient mesh): user → agent → tool, proxy exchanges
#
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="kagenti"
AGENT_TOOL_URL="http://demo-agent.agent-ns.svc.cluster.local:8080/call/echo-tool"
AGENT_TIME_URL="http://demo-agent.agent-ns.svc.cluster.local:8080/call/time-tool"
INVALID_TOKEN="invalid-token-12345"
PASS=0
FAIL=0
PF_PID=""

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAIL=$((FAIL + 1)); }
detail(){ echo -e "        $*"; }

# Decode JWT payload (handles base64url padding on both Linux and macOS)
jwt_payload() {
  local payload
  payload=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  [[ $pad -lt 4 ]] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  echo "$payload" | base64 -d 2>/dev/null
}

# Print key JWT claims in a readable format
print_token_info() {
  local label="$1"
  local token="$2"
  local payload
  payload=$(jwt_payload "$token")

  local iss aud azp sub exp
  iss=$(echo "$payload" | jq -r '.iss // "n/a"')
  aud=$(echo "$payload" | jq -r 'if .aud | type == "array" then (.aud | join(", ")) else (.aud // "n/a") end')
  azp=$(echo "$payload" | jq -r '.azp // "n/a"')
  sub=$(echo "$payload" | jq -r '.sub // "n/a"')
  exp=$(echo "$payload" | jq -r '.exp // 0')

  # Convert exp to human-readable
  local exp_human="n/a"
  if [[ "$exp" != "0" && "$exp" != "null" ]]; then
    exp_human=$(date -r "$exp" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$exp" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$exp")
  fi

  detail "$label:"
  detail "  iss: $iss"
  detail "  sub: $sub"
  detail "  aud: $aud"
  detail "  azp: $azp"
  detail "  exp: $exp_human"
}

# Run a curl command against demo-agent inside agent-ns via a short-lived pod.
# Usage: run_curl <pod-name> <auth-header-value> [url] → sets CURL_BODY
run_curl() {
  local pod_name="$1"
  local auth_value="$2"
  local url="${3:-$AGENT_TOOL_URL}"

  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true

  kubectl run "$pod_name" -n agent-ns \
    --image=curlimages/curl:latest \
    --restart=Never \
    --command -- sh -c \
    "curl -s -H 'Authorization: ${auth_value}' '${url}'" \
    2>/dev/null

  kubectl wait --for=condition=ready "pod/$pod_name" -n agent-ns --timeout=30s 2>/dev/null || true
  sleep 5

  CURL_BODY=$(kubectl logs -n agent-ns "$pod_name" 2>&1) || true
  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true
}

PROXY_TEST_NS="proxy-test-ns"

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-invalid --force --grace-period=0 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-valid --force --grace-period=0 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-time --force --grace-period=0 2>/dev/null || true
  kubectl delete ns "$PROXY_TEST_NS" --force --grace-period=0 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Wait for readiness ----------

info "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=keycloak -n "$KEYCLOAK_NS" --timeout=180s
kubectl wait --for=condition=ready pod -l app=demo-agent -n agent-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=echo-tool -n tool-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=time-tool -n tool-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=token-exchange-service -n kagenti-system --timeout=60s

# ==========================================================================
# Test 1: Invalid token is rejected
# ==========================================================================

echo ""
info "Test 1: Invalid token is rejected"
detail "Token: Bearer $INVALID_TOKEN"
detail "This is not a valid JWT — no header, payload, or signature."
detail "User sends it to demo-agent → demo-agent forwards to echo-tool"
detail "→ waypoint ext_authz rejects (JWT validation fails)"
echo ""

run_curl "curl-invalid" "Bearer $INVALID_TOKEN"

TOOL_STATUS=$(echo "$CURL_BODY" | jq -r '.tool_status // empty' 2>/dev/null)

if [[ -z "$TOOL_STATUS" ]]; then
  # No tool_status means the request never reached demo-agent.
  # This happens when the agent-waypoint rejects the token on inbound.
  WAYPOINT_ERROR=$(echo "$CURL_BODY" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "$WAYPOINT_ERROR" ]] && echo "$WAYPOINT_ERROR" | grep -qi "invalid token\|malformed\|unauthorized\|audience"; then
    detail "Rejected by agent-waypoint (inbound): $WAYPOINT_ERROR"
    ok "Invalid token rejected by agent-waypoint before reaching demo-agent"
  else
    detail "Response: $CURL_BODY"
    fail "Unexpected response (no tool_status, no recognized error)"
  fi
elif [[ "$TOOL_STATUS" == "401" || "$TOOL_STATUS" == "403" ]]; then
  TOOL_BODY=$(echo "$CURL_BODY" | jq -r '.tool_response_raw // empty' 2>/dev/null)
  REJECT_REASON=$(echo "$TOOL_BODY" | jq -r '.error // empty' 2>/dev/null)
  detail "demo-agent → echo-tool: HTTP $TOOL_STATUS"
  if [[ -n "$REJECT_REASON" ]]; then
    detail "Rejection reason: $REJECT_REASON"
  fi
  ok "Invalid token rejected by waypoint (HTTP $TOOL_STATUS)"
else
  fail "Expected tool_status 401 or 403, got $TOOL_STATUS"
  detail "Response: $CURL_BODY"
fi

# ==========================================================================
# Test 2: Valid token is exchanged and accepted
# ==========================================================================

echo ""
info "Test 2: Valid token is exchanged and accepted"

# Obtain a user token from Keycloak (out-of-band, aud=demo-agent)
detail "Obtaining user token from Keycloak..."
# Kill any stale port-forward on 18080 (e.g. left over from make up)
{ lsof -ti tcp:18080 | xargs kill; } 2>/dev/null || true
sleep 1
kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" 18080:8080 &
PF_PID=$!
sleep 3

KC_TOKEN_URL="http://localhost:18080/realms/$REALM/protocol/openid-connect/token"
USER_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=demo-agent" \
  -d "client_secret=agent-secret" | jq -r '.access_token')

if [[ -z "$USER_TOKEN" || "$USER_TOKEN" == "null" ]]; then
  fail "Could not obtain user token from Keycloak"
  exit 1
fi

USER_AUD=$(jwt_payload "$USER_TOKEN" | jq -r 'if .aud | type == "array" then (.aud | join(", ")) else (.aud // "n/a") end')
USER_AZP=$(jwt_payload "$USER_TOKEN" | jq -r '.azp // "n/a"')
USER_SUB=$(jwt_payload "$USER_TOKEN" | jq -r '.sub // "n/a"')

echo ""
print_token_info "User token (before exchange)" "$USER_TOKEN"
echo ""
detail "User sends this token to demo-agent → demo-agent forwards to echo-tool"
detail "→ waypoint ext_authz validates JWT, exchanges via RFC 8693"
detail "→ echo-tool should receive a new token with aud=echo-tool"
echo ""

run_curl "curl-valid" "Bearer $USER_TOKEN"

TOOL_STATUS=$(echo "$CURL_BODY" | jq -r '.tool_status // empty' 2>/dev/null)

if [[ "$TOOL_STATUS" != "200" ]]; then
  fail "Expected tool_status 200, got $TOOL_STATUS"
  detail "Response: $CURL_BODY"
  detail "Debug: kubectl logs -n kagenti-system -l app=token-exchange-service"
else
  # Extract the token that echo-tool received from the echoed headers
  TOOL_RESPONSE=$(echo "$CURL_BODY" | jq -r '.tool_response_raw // empty' 2>/dev/null)
  RECEIVED_AUTH=$(echo "$TOOL_RESPONSE" | jq -r '.headers.Authorization // .headers.authorization // empty')

  if [[ -z "$RECEIVED_AUTH" ]]; then
    fail "echo-tool did not receive an Authorization header"
  else
    RECEIVED_TOKEN=$(echo "$RECEIVED_AUTH" | sed 's/Bearer //')

    print_token_info "Token received by echo-tool (after exchange)" "$RECEIVED_TOKEN"
    echo ""

    RECEIVED_AUD=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.aud // "unknown"')
    RECEIVED_AZP=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.azp // "unknown"')
    RECEIVED_SUB=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.sub // "unknown"')

    if [[ "$RECEIVED_TOKEN" == "$USER_TOKEN" ]]; then
      fail "Token was NOT exchanged — echo-tool received the original user token"
    elif echo "$RECEIVED_AUD" | grep -q "echo-tool"; then
      ok "Token exchanged — echo-tool received token with aud=$RECEIVED_AUD"
      detail "Exchange summary:"
      detail "  aud: [$USER_AUD] → $RECEIVED_AUD"
      detail "  azp: $USER_AZP → $RECEIVED_AZP"
      detail "  sub: $USER_SUB → $RECEIVED_SUB (preserved)"
    else
      fail "Unexpected audience: $RECEIVED_AUD (expected echo-tool)"
    fi
  fi
fi

# ==========================================================================
# Test 3: Valid token is exchanged for time-tool (second tool, same waypoint)
# ==========================================================================

echo ""
info "Test 3: Valid token is exchanged for time-tool (second tool, same waypoint)"
detail "Same user token, different tool → proves one waypoint handles N tools"
detail "User sends token to demo-agent /call/time-tool → demo-agent forwards to time-tool"
detail "→ tool-waypoint ext_authz validates JWT, exchanges via RFC 8693"
detail "→ time-tool should receive a new token with aud=time-tool"
echo ""
print_token_info "User token (before exchange)" "$USER_TOKEN"
echo ""

run_curl "curl-time" "Bearer $USER_TOKEN" "$AGENT_TIME_URL"

TOOL_STATUS=$(echo "$CURL_BODY" | jq -r '.tool_status // empty' 2>/dev/null)

if [[ "$TOOL_STATUS" != "200" ]]; then
  fail "Expected tool_status 200, got $TOOL_STATUS"
  detail "Response: $CURL_BODY"
  detail "Debug: kubectl logs -n kagenti-system -l app=token-exchange-service"
else
  TOOL_RESPONSE=$(echo "$CURL_BODY" | jq -r '.tool_response_raw // empty' 2>/dev/null)
  RECEIVED_AUD=$(echo "$TOOL_RESPONSE" | jq -r '.token_aud // "unknown"')
  RECEIVED_AZP=$(echo "$TOOL_RESPONSE" | jq -r '.token_azp // "unknown"')
  RECEIVED_SUB=$(echo "$TOOL_RESPONSE" | jq -r '.token_sub // "unknown"')
  RECEIVED_TIME=$(echo "$TOOL_RESPONSE" | jq -r '.time // "unknown"')

  detail "Token received by time-tool (after exchange):"
  detail "  aud: $RECEIVED_AUD"
  detail "  azp: $RECEIVED_AZP"
  detail "  sub: $RECEIVED_SUB"
  detail "  time: $RECEIVED_TIME"
  echo ""

  if echo "$RECEIVED_AUD" | grep -q "time-tool"; then
    ok "Token exchanged — time-tool received token with aud=$RECEIVED_AUD"
    detail "Exchange summary:"
    detail "  aud: [$USER_AUD] → $RECEIVED_AUD"
    detail "  azp: $USER_AZP → $RECEIVED_AZP"
    detail "  sub: $USER_SUB → $RECEIVED_SUB (preserved)"
  else
    fail "Unexpected audience: $RECEIVED_AUD (expected time-tool)"
  fi
fi

# ==========================================================================
# Test 4: HTTP proxy mode — full E2E without ambient mesh
# ==========================================================================

echo ""
info "Test 4: HTTP proxy mode — user → agent → tool (no ambient mesh)"
detail "Deploy demo-agent + echo-tool in a non-ambient namespace"
detail "Both use HTTP_PROXY for token exchange instead of waypoint"
echo ""

PROXY_URL="http://token-exchange-service.kagenti-system.svc.cluster.local:8080"

# Create a non-ambient namespace (no istio labels)
kubectl create ns "$PROXY_TEST_NS" 2>/dev/null || true

# Deploy echo-tool in proxy-test-ns (no ambient, no waypoint)
kubectl apply -n "$PROXY_TEST_NS" -f - <<'PROXY_TOOL_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-tool
  labels:
    app: echo-tool
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-tool
  template:
    metadata:
      labels:
        app: echo-tool
    spec:
      containers:
        - name: echo-tool
          image: localhost:5000/echo-tool:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echo-tool
spec:
  selector:
    app: echo-tool
  ports:
    - port: 8080
      targetPort: 8080
PROXY_TOOL_EOF

# Deploy demo-agent in proxy-test-ns with HTTP_PROXY
kubectl apply -n "$PROXY_TEST_NS" -f - <<PROXY_AGENT_EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-agent
  labels:
    app: demo-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-agent
  template:
    metadata:
      labels:
        app: demo-agent
    spec:
      containers:
        - name: demo-agent
          image: localhost:5000/demo-agent:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: TOOL_NS
              value: "$PROXY_TEST_NS"
            - name: HTTP_PROXY
              value: "$PROXY_URL"
            - name: NO_PROXY
              value: "localhost,127.0.0.1"
---
apiVersion: v1
kind: Service
metadata:
  name: demo-agent
spec:
  selector:
    app: demo-agent
  ports:
    - port: 8080
      targetPort: 8080
PROXY_AGENT_EOF

detail "Waiting for pods in $PROXY_TEST_NS (no ambient mesh)..."
kubectl wait --for=condition=ready pod -l app=echo-tool -n "$PROXY_TEST_NS" --timeout=60s 2>/dev/null
kubectl wait --for=condition=ready pod -l app=demo-agent -n "$PROXY_TEST_NS" --timeout=60s 2>/dev/null

# Verify no ambient mesh — no waypoint, no ztunnel interception
detail "Namespace $PROXY_TEST_NS has NO ambient mesh labels"

print_token_info "User token (before exchange)" "$USER_TOKEN"
echo ""

# Call agent → agent calls tool via HTTP_PROXY → proxy exchanges token
PROXY_AGENT_URL="http://demo-agent.$PROXY_TEST_NS.svc.cluster.local:8080/call/echo-tool"
kubectl delete pod -n "$PROXY_TEST_NS" curl-proxy --force --grace-period=0 2>/dev/null || true

kubectl run curl-proxy -n "$PROXY_TEST_NS" \
  --image=curlimages/curl:latest \
  --restart=Never \
  --command -- sh -c \
  "curl -s -H 'Authorization: Bearer ${USER_TOKEN}' '${PROXY_AGENT_URL}'" \
  2>/dev/null

kubectl wait --for=condition=ready "pod/curl-proxy" -n "$PROXY_TEST_NS" --timeout=30s 2>/dev/null || true
sleep 5

CURL_BODY=$(kubectl logs -n "$PROXY_TEST_NS" curl-proxy 2>&1) || true

TOOL_STATUS=$(echo "$CURL_BODY" | jq -r '.tool_status // empty' 2>/dev/null)

if [[ "$TOOL_STATUS" != "200" ]]; then
  fail "Proxy mode: expected tool_status 200, got $TOOL_STATUS"
  detail "Response: $CURL_BODY"
  detail "Debug: kubectl logs -n kagenti-system -l app=token-exchange-service --tail=10"
else
  TOOL_RESPONSE=$(echo "$CURL_BODY" | jq -r '.tool_response_raw // empty' 2>/dev/null)
  RECEIVED_AUTH=$(echo "$TOOL_RESPONSE" | jq -r '.headers.Authorization // .headers.authorization // empty')

  if [[ -z "$RECEIVED_AUTH" ]]; then
    fail "echo-tool did not receive an Authorization header via proxy"
  else
    RECEIVED_TOKEN=$(echo "$RECEIVED_AUTH" | sed 's/Bearer //')

    print_token_info "Token received by echo-tool (via proxy, no mesh)" "$RECEIVED_TOKEN"
    echo ""

    RECEIVED_AUD=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.aud // "unknown"')
    RECEIVED_AZP=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.azp // "unknown"')
    RECEIVED_SUB=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.sub // "unknown"')

    if [[ "$RECEIVED_TOKEN" == "$USER_TOKEN" ]]; then
      fail "Token was NOT exchanged via proxy"
    elif echo "$RECEIVED_AUD" | grep -q "echo-tool"; then
      ok "Proxy mode: user → agent → tool, token exchanged (aud=$RECEIVED_AUD)"
      detail "Exchange summary (HTTP_PROXY, no ambient mesh):"
      detail "  aud: [$USER_AUD] → $RECEIVED_AUD"
      detail "  azp: $USER_AZP → $RECEIVED_AZP"
      detail "  sub: $USER_SUB → $RECEIVED_SUB (preserved)"
    else
      fail "Unexpected audience via proxy: $RECEIVED_AUD (expected echo-tool)"
    fi
  fi
fi

# ---------- Summary ----------

echo ""
echo "=============================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
