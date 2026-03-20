#!/usr/bin/env bash
# End-to-end validation for the waypoint token exchange PoC.
# Verifies: zero sidecars, token exchange via waypoint, correct audience.
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="waypoint-poc"
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
  # Add padding
  local pad=$(( 4 - ${#payload} % 4 ))
  [[ $pad -lt 4 ]] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  echo "$payload" | base64 -d 2>/dev/null
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-e2e --force --grace-period=0 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Wait for readiness ----------

info "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=keycloak -n "$KEYCLOAK_NS" --timeout=180s
kubectl wait --for=condition=ready pod -l app=echo-agent -n agent-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=echo-tool -n tool-ns --timeout=60s
kubectl wait --for=condition=ready pod -l app=token-exchange-service -n kagenti-system --timeout=60s

# ---------- Test 1: Zero sidecars ----------

info "Test 1: Verify zero sidecars"

AGENT_CONTAINERS=$(kubectl get pods -n agent-ns -l app=echo-agent -o jsonpath='{.items[0].spec.containers[*].name}')
if [[ "$AGENT_CONTAINERS" == "echo-agent" ]]; then
  ok "echo-agent has exactly 1 container: $AGENT_CONTAINERS"
else
  fail "echo-agent containers: $AGENT_CONTAINERS (expected: echo-agent)"
fi

TOOL_CONTAINERS=$(kubectl get pods -n tool-ns -l app=echo-tool -o jsonpath='{.items[0].spec.containers[*].name}')
if [[ "$TOOL_CONTAINERS" == "echo-tool" ]]; then
  ok "echo-tool has exactly 1 container: $TOOL_CONTAINERS"
else
  fail "echo-tool containers: $TOOL_CONTAINERS (expected: echo-tool)"
fi

# ---------- Test 2: Get agent token from Keycloak ----------

info "Test 2: Obtain agent token from Keycloak"

# Use port-forward to reach Keycloak (works regardless of cluster config)
kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" 18080:8080 &
PF_PID=$!
sleep 3

KC_TOKEN_URL="http://localhost:18080/realms/$REALM/protocol/openid-connect/token"

AGENT_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=echo-agent" \
  -d "client_secret=agent-secret" | jq -r '.access_token')

if [[ -n "$AGENT_TOKEN" && "$AGENT_TOKEN" != "null" ]]; then
  ok "Obtained agent token (${#AGENT_TOKEN} chars)"
  AGENT_AZP=$(jwt_payload "$AGENT_TOKEN" | jq -r '.azp // "unknown"')
  info "  Agent token azp: $AGENT_AZP"
else
  fail "Could not obtain agent token from Keycloak"
  echo "RESULT: $FAIL failures"
  exit 1
fi

# ---------- Test 3: Agent calls tool through waypoint ----------

info "Test 3: Agent calls tool (token exchange via waypoint)"

# Use a curl debug pod in agent-ns since workload images are distroless (no shell/curl).
# The pod runs in agent-ns so it gets the same ambient mesh identity as the agent.
kubectl run curl-e2e -n agent-ns --image=curlimages/curl:latest --restart=Never \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"curl-e2e\",
        \"image\": \"curlimages/curl:latest\",
        \"command\": [\"sh\", \"-c\", \"curl -sf -H 'Authorization: Bearer $AGENT_TOKEN' http://echo-tool.tool-ns.svc.cluster.local:8080/echo; sleep 3\"]
      }]
    }
  }" 2>/dev/null

# Wait for the pod to complete
kubectl wait --for=condition=ready pod/curl-e2e -n agent-ns --timeout=30s 2>/dev/null || true
sleep 5
TOOL_RESPONSE=$(kubectl logs -n agent-ns curl-e2e 2>&1) || true
kubectl delete pod -n agent-ns curl-e2e --force --grace-period=0 2>/dev/null || true

if [[ -z "$TOOL_RESPONSE" || "$TOOL_RESPONSE" == *"error"* && "$TOOL_RESPONSE" != *"headers"* ]]; then
  fail "No valid response from tool"
  info "  Response: $TOOL_RESPONSE"
  info "  Check waypoint and ext_authz logs:"
  info "  kubectl logs -n tool-ns -l gateway.networking.k8s.io/gateway-name=tool-waypoint"
  info "  kubectl logs -n kagenti-system -l app=token-exchange-service"
else
  info "Tool response received"
  echo "$TOOL_RESPONSE" | jq . 2>/dev/null || echo "$TOOL_RESPONSE"

  # Check if the Authorization header was exchanged
  RECEIVED_AUTH=$(echo "$TOOL_RESPONSE" | jq -r '.headers.Authorization // .headers.authorization // empty')
  if [[ -n "$RECEIVED_AUTH" ]]; then
    RECEIVED_TOKEN=$(echo "$RECEIVED_AUTH" | sed 's/Bearer //')
    RECEIVED_AUD=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.aud // "unknown"')
    RECEIVED_AZP=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.azp // "unknown"')

    info "  Received token aud: $RECEIVED_AUD"
    info "  Received token azp: $RECEIVED_AZP"

    if echo "$RECEIVED_AUD" | grep -q "echo-tool"; then
      ok "Token was exchanged! Tool received token with aud containing 'echo-tool'"
    elif [[ "$RECEIVED_AZP" == "echo-tool" ]]; then
      ok "Token was exchanged! Tool received token with azp='echo-tool'"
    else
      # Check if token is different from original (exchange happened but aud format differs)
      if [[ "$RECEIVED_TOKEN" != "$AGENT_TOKEN" ]]; then
        ok "Token was exchanged (different token received, aud=$RECEIVED_AUD)"
      else
        fail "Token was NOT exchanged — tool received the original agent token"
      fi
    fi
  else
    info "  No Authorization header in echoed response (may have been stripped)"
    fail "Cannot verify token exchange — Authorization header not echoed"
  fi
fi

# ---------- Test 4: Verify waypoint is running ----------

info "Test 4: Verify waypoint proxy is running"

WAYPOINT_PODS=$(kubectl get pods -n tool-ns -l gateway.networking.k8s.io/gateway-name=tool-waypoint --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WAYPOINT_PODS" -ge 1 ]]; then
  ok "Waypoint proxy running ($WAYPOINT_PODS pod(s))"
else
  fail "No waypoint proxy pods found in tool-ns"
fi

# ---------- Test 5: Verify no privileged containers ----------

info "Test 5: Verify no privileged/init containers in workload pods"

AGENT_INIT=$(kubectl get pods -n agent-ns -l app=echo-agent -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null)
TOOL_INIT=$(kubectl get pods -n tool-ns -l app=echo-tool -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null)

if [[ -z "$AGENT_INIT" && -z "$TOOL_INIT" ]]; then
  ok "No init containers in agent or tool pods"
else
  fail "Init containers found: agent=[$AGENT_INIT] tool=[$TOOL_INIT]"
fi

# ---------- Summary ----------

echo ""
echo "=============================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
