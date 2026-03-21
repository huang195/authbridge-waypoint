#!/usr/bin/env bash
# End-to-end tests for the waypoint token exchange PoC.
#
# Test architecture:
#
#   User (curl pod, agent-ns)
#     │
#     │  POST /call-tool  +  Authorization: Bearer <user-token>
#     ▼
#   echo-agent (agent-ns)
#     │
#     │  GET /echo  (forwards user token to echo-tool)
#     ▼
#   agent-waypoint (agent-ns, workload-level)
#     │
#     ├─ CUSTOM AuthorizationPolicy → ext_authz (token-exchange-service)
#     │    • Validates JWT signature, issuer, expiry via Keycloak JWKS
#     │    • Exchanges token for tool-scoped token via RFC 8693
#     │    • Replaces Authorization header with exchanged token (aud=echo-tool)
#     │
#     ▼
#   ztunnel (L4 mTLS)
#     │
#     ▼
#   echo-tool (tool-ns, no waypoint — just a plain pod in ambient mesh)
#     │
#     └─ Returns JSON with all received headers (including Authorization)
#
# The waypoint is on the AGENT side (attached to the agent's ServiceAccount),
# not the tool side. Token validation and exchange happen on behalf of the agent.
#
# Tests:
#   1. Invalid token → user sends bad token to echo-agent → agent forwards →
#      agent waypoint rejects (ext_authz denies)
#   2. Valid token   → user sends valid token to echo-agent → agent forwards →
#      agent waypoint exchanges → tool receives aud=echo-tool
#
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="waypoint-poc"
AGENT_URL="http://echo-agent.agent-ns.svc.cluster.local:8080/call-tool"
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

# Run a curl command against echo-agent inside agent-ns via a short-lived pod.
# Usage: run_curl <pod-name> <auth-header-value> → sets CURL_BODY
run_curl() {
  local pod_name="$1"
  local auth_value="$2"

  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true

  kubectl run "$pod_name" -n agent-ns \
    --image=curlimages/curl:latest \
    --restart=Never \
    --command -- sh -c \
    "curl -s -H 'Authorization: ${auth_value}' '${AGENT_URL}'" \
    2>/dev/null

  kubectl wait --for=condition=ready "pod/$pod_name" -n agent-ns --timeout=30s 2>/dev/null || true
  sleep 5

  CURL_BODY=$(kubectl logs -n agent-ns "$pod_name" 2>&1) || true
  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-invalid --force --grace-period=0 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-valid --force --grace-period=0 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Wait for readiness ----------

info "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=keycloak -n "$KEYCLOAK_NS" --timeout=180s
kubectl wait --for=condition=ready pod -l app=echo-agent -n agent-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=echo-tool -n tool-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=token-exchange-service -n kagenti-system --timeout=60s

# ==========================================================================
# Test 1: Invalid token is rejected
# ==========================================================================

echo ""
info "Test 1: Invalid token is rejected"
detail "Token: Bearer $INVALID_TOKEN"
detail "This is not a valid JWT — no header, payload, or signature."
detail "User sends it to echo-agent → echo-agent forwards to echo-tool"
detail "→ waypoint ext_authz rejects (JWT validation fails)"
echo ""

run_curl "curl-invalid" "Bearer $INVALID_TOKEN"

TOOL_STATUS=$(echo "$CURL_BODY" | jq -r '.tool_status // empty' 2>/dev/null)

if [[ -z "$TOOL_STATUS" ]]; then
  detail "Response: $CURL_BODY"
  AGENT_ERROR=$(echo "$CURL_BODY" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "$AGENT_ERROR" ]]; then
    fail "echo-agent returned error before reaching waypoint: $AGENT_ERROR"
  else
    fail "Unexpected response from echo-agent"
  fi
elif [[ "$TOOL_STATUS" == "401" || "$TOOL_STATUS" == "403" ]]; then
  TOOL_BODY=$(echo "$CURL_BODY" | jq -r '.tool_response_raw // empty' 2>/dev/null)
  REJECT_REASON=$(echo "$TOOL_BODY" | jq -r '.error // empty' 2>/dev/null)
  detail "echo-agent → echo-tool: HTTP $TOOL_STATUS"
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

# Obtain a user token from Keycloak (out-of-band, aud=echo-agent)
detail "Obtaining user token from Keycloak..."
kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" 18080:8080 &
PF_PID=$!
sleep 3

KC_TOKEN_URL="http://localhost:18080/realms/$REALM/protocol/openid-connect/token"
USER_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=echo-agent" \
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
detail "User sends this token to echo-agent → echo-agent forwards to echo-tool"
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

# ---------- Summary ----------

echo ""
echo "=============================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
