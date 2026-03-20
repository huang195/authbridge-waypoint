#!/usr/bin/env bash
# End-to-end tests for the waypoint token exchange PoC.
#
# Test architecture:
#
#   curl pod (agent-ns)
#        │
#        │  GET /echo  +  Authorization: Bearer <token>
#        ▼
#   ztunnel (L4 mTLS)
#        │
#        ▼
#   waypoint (tool-ns)
#        │
#        ├─ CUSTOM AuthorizationPolicy → ext_authz (token-exchange-service)
#        │    • Validates JWT signature, issuer, expiry via Keycloak JWKS
#        │    • Exchanges agent token for tool-scoped token via RFC 8693
#        │    • Replaces Authorization header with exchanged token
#        │
#        ├─ ALLOW AuthorizationPolicy → only agent-ns sources permitted
#        │
#        ▼
#   echo-tool (tool-ns)
#        │
#        └─ Returns JSON with all received headers (including Authorization)
#
# Tests:
#   1. Invalid token → waypoint rejects the request (ext_authz denies)
#   2. Valid token   → token is exchanged, tool receives aud=echo-tool
#
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="waypoint-poc"
TOOL_URL="http://echo-tool.tool-ns.svc.cluster.local:8080/echo"
PASS=0
FAIL=0
PF_PID=""

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAIL=$((FAIL + 1)); }

# Decode JWT payload (handles base64url padding on both Linux and macOS)
jwt_payload() {
  local payload
  payload=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  [[ $pad -lt 4 ]] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  echo "$payload" | base64 -d 2>/dev/null
}

# Run a curl command inside agent-ns via a short-lived pod.
# Writes a script to a ConfigMap to avoid JSON/shell quoting issues.
# Usage: run_curl <pod-name> <auth-header-value> → sets CURL_HTTP_CODE and CURL_BODY
run_curl() {
  local pod_name="$1"
  local auth_value="$2"

  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true

  kubectl run "$pod_name" -n agent-ns \
    --image=curlimages/curl:latest \
    --restart=Never \
    --command -- sh -c \
    "HTTP_CODE=\$(curl -s -o /tmp/body -w '%{http_code}' -H 'Authorization: ${auth_value}' '${TOOL_URL}'); echo \"\${HTTP_CODE}\"; cat /tmp/body" \
    2>/dev/null

  kubectl wait --for=condition=ready "pod/$pod_name" -n agent-ns --timeout=30s 2>/dev/null || true
  sleep 5

  local output
  output=$(kubectl logs -n agent-ns "$pod_name" 2>&1) || true
  kubectl delete pod -n agent-ns "$pod_name" --force --grace-period=0 2>/dev/null || true

  # First line is the HTTP status code, rest is the body
  CURL_HTTP_CODE=$(echo "$output" | head -1 | tr -d '[:space:]')
  CURL_BODY=$(echo "$output" | tail -n +2)
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
kubectl wait --for=condition=ready pod -l app=echo-tool -n tool-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=token-exchange-service -n kagenti-system --timeout=60s

# ---------- Get agent token from Keycloak ----------

info "Obtaining agent token from Keycloak..."
kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" 18080:8080 &
PF_PID=$!
sleep 3

KC_TOKEN_URL="http://localhost:18080/realms/$REALM/protocol/openid-connect/token"
AGENT_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=echo-agent" \
  -d "client_secret=agent-secret" | jq -r '.access_token')

if [[ -z "$AGENT_TOKEN" || "$AGENT_TOKEN" == "null" ]]; then
  fail "Could not obtain agent token from Keycloak"
  exit 1
fi
info "Agent token obtained (azp: $(jwt_payload "$AGENT_TOKEN" | jq -r '.azp'))"

# ---------- Test 1: Invalid token is rejected ----------

info "Test 1: Invalid token is rejected by waypoint"

run_curl "curl-invalid" "Bearer invalid-token-12345"

if [[ "$CURL_HTTP_CODE" == "401" || "$CURL_HTTP_CODE" == "403" ]]; then
  ok "Invalid token rejected (HTTP $CURL_HTTP_CODE)"
else
  fail "Expected 401 or 403 for invalid token, got HTTP $CURL_HTTP_CODE"
  info "  Response: $CURL_BODY"
fi

# ---------- Test 2: Valid token is exchanged and accepted ----------

info "Test 2: Valid token is exchanged and accepted by tool"

run_curl "curl-valid" "Bearer $AGENT_TOKEN"

if [[ "$CURL_HTTP_CODE" != "200" ]]; then
  fail "Expected HTTP 200, got $CURL_HTTP_CODE"
  info "  Response: $CURL_BODY"
  info "  Debug: kubectl logs -n kagenti-system -l app=token-exchange-service"
else
  RECEIVED_AUTH=$(echo "$CURL_BODY" | jq -r '.headers.Authorization // .headers.authorization // empty')
  if [[ -z "$RECEIVED_AUTH" ]]; then
    fail "Tool did not receive an Authorization header"
  else
    RECEIVED_TOKEN=$(echo "$RECEIVED_AUTH" | sed 's/Bearer //')
    RECEIVED_AUD=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.aud // "unknown"')

    if [[ "$RECEIVED_TOKEN" == "$AGENT_TOKEN" ]]; then
      fail "Token was NOT exchanged — tool received the original agent token"
    elif echo "$RECEIVED_AUD" | grep -q "echo-tool"; then
      ok "Token exchanged — tool received token with aud=$RECEIVED_AUD"
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
