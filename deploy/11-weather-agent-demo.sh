#!/usr/bin/env bash
# Deploy the kagenti weather agent + tool with waypoint security.
#
# Deploys the REAL kagenti weather-service agent and weather-tool MCP server
# (ghcr.io images, unmodified) into waypoint-protected namespaces.
# Use the kagenti UI to interact with the agent after deployment.
#
# Prerequisites:
#   - System deployed via "make up" with tests passing
#   - Ollama running locally with llama3.2:3b-instruct-fp16
#
# Usage: bash deploy/11-weather-agent-demo.sh
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="kagenti"
KC_PORT=18080
PF_PID=""

# ---------- Cleanup mode ----------

if [[ "${1:-}" == "--cleanup" ]]; then
  echo "Cleaning up weather agent demo..."

  kubectl delete -f deploy/weather-service.yaml 2>/dev/null && echo "  Deleted weather-service" || true
  kubectl delete -f deploy/weather-tool-mcp.yaml 2>/dev/null && echo "  Deleted weather-tool" || true

  { lsof -ti tcp:$KC_PORT | xargs kill; } 2>/dev/null || true
  sleep 1
  kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" $KC_PORT:8080 &>/dev/null &
  PF_PID=$!
  sleep 3

  KC_URL="http://localhost:$KC_PORT"
  ADMIN_TOKEN=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token')

  EXCHANGE_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=token-exchange-service" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

  for CLIENT in weather-service weather-tool-mcp; do
    UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=$CLIENT" \
      -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')
    if [[ -n "$UUID" && "$UUID" != "null" ]]; then
      curl -sf -o /dev/null -X DELETE "$KC_URL/admin/realms/$REALM/clients/$UUID" \
        -H "Authorization: Bearer $ADMIN_TOKEN" && echo "  Deleted Keycloak client $CLIENT" || true
    fi
  done

  for MAPPER in weather-tool-mcp-audience weather-service-audience; do
    MAPPER_ID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models" \
      -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r ".[] | select(.name==\"$MAPPER\") | .id")
    if [[ -n "$MAPPER_ID" && "$MAPPER_ID" != "null" ]]; then
      curl -sf -o /dev/null -X DELETE "$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models/$MAPPER_ID" \
        -H "Authorization: Bearer $ADMIN_TOKEN" && echo "  Deleted audience mapper $MAPPER" || true
    fi
  done

  kill "$PF_PID" 2>/dev/null || true
  echo "  Done."
  exit 0
fi

# ---------- Demo helpers ----------

CYAN='\033[1;36m'
GREEN='\033[1;32m'
DIM='\033[2m'
RESET='\033[0m'

narrate() { echo -e "\n${CYAN}$*${RESET}"; }
prompt()  { echo -e "${DIM}press enter to continue...${RESET}"; read -r; }

run() {
  printf "\n${GREEN}\$ %s${RESET}" "$*"
  read -r
  eval "$@"
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Setup: Keycloak access ----------

clear
echo -n "Connecting to Keycloak..."
{ lsof -ti tcp:$KC_PORT | xargs kill; } 2>/dev/null || true
sleep 1
kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" $KC_PORT:8080 &>/dev/null &
PF_PID=$!
sleep 3

KC_URL="http://localhost:$KC_PORT"

ADMIN_TOKEN=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token')
echo " ready."

EXCHANGE_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=token-exchange-service" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

add_mapper() {
  local client_uuid="$1" name="$2" aud="$3"
  curl -s -o /dev/null -X POST \
    "$KC_URL/admin/realms/$REALM/clients/$client_uuid/protocol-mappers/models" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$name\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"consentRequired\": false,
      \"config\": {
        \"included.client.audience\": \"$aud\",
        \"id.token.claim\": \"false\",
        \"access.token.claim\": \"true\"
      }
    }" 2>/dev/null || true
}

# ---------- Step 1: Register in Keycloak ----------

narrate "Step 1: Register weather-service (agent) and weather-tool-mcp (tool) in Keycloak"

run "HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST '$KC_URL/admin/realms/$REALM/clients' \\
  -H 'Authorization: Bearer $ADMIN_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"clientId\": \"weather-service\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"secret\": \"weather-service-secret\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false
  }')
if [ \"\$HTTP_CODE\" = '201' ]; then echo '  Created client weather-service';
elif [ \"\$HTTP_CODE\" = '409' ]; then echo '  Client weather-service already exists (OK)';
else echo \"  WARNING: HTTP \$HTTP_CODE\"; fi"

AGENT_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=weather-service" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

add_mapper "$AGENT_UUID" "weather-service-audience" "weather-service"
add_mapper "$AGENT_UUID" "weather-service-exchange-audience" "token-exchange-service"
echo "  Agent audience mappers configured"

# Ensure kagenti platform client includes token-exchange-service in audience
# so the ext_authz can exchange tokens from the kagenti UI/backend.
KAGENTI_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=kagenti" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')
if [[ -n "$KAGENTI_UUID" && "$KAGENTI_UUID" != "null" ]]; then
  add_mapper "$KAGENTI_UUID" "token-exchange-service-audience" "token-exchange-service"
  echo "  Kagenti platform audience mapper configured"
fi

run "HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST '$KC_URL/admin/realms/$REALM/clients' \\
  -H 'Authorization: Bearer $ADMIN_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"clientId\": \"weather-tool-mcp\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"secret\": \"weather-tool-secret\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false
  }')
if [ \"\$HTTP_CODE\" = '201' ]; then echo '  Created client weather-tool-mcp';
elif [ \"\$HTTP_CODE\" = '409' ]; then echo '  Client weather-tool-mcp already exists (OK)';
else echo \"  WARNING: HTTP \$HTTP_CODE\"; fi"

run "HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST \\
  '$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models' \\
  -H 'Authorization: Bearer $ADMIN_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"name\": \"weather-tool-mcp-audience\",
    \"protocol\": \"openid-connect\",
    \"protocolMapper\": \"oidc-audience-mapper\",
    \"consentRequired\": false,
    \"config\": {
      \"included.client.audience\": \"weather-tool-mcp\",
      \"id.token.claim\": \"false\",
      \"access.token.claim\": \"true\"
    }
  }')
if [ \"\$HTTP_CODE\" = '201' ]; then echo '  Created audience mapper weather-tool-mcp-audience';
elif [ \"\$HTTP_CODE\" = '409' ]; then echo '  Mapper already exists (OK)';
else echo \"  WARNING: HTTP \$HTTP_CODE\"; fi"

# token-exchange-service also needs weather-service as a valid audience
# for inbound exchange (when kagenti UI calls the agent through the waypoint).
add_mapper "$EXCHANGE_UUID" "weather-service-audience" "weather-service"
echo "  Exchange service audience mappers configured"

# ---------- Step 2: Deploy ----------

narrate "Step 2: Deploy kagenti weather agent + tool (unmodified ghcr.io images)"

run "kubectl apply -f deploy/weather-service.yaml"

run "kubectl apply -f deploy/weather-tool-mcp.yaml"

narrate "Waiting for pods..."
kubectl wait --for=condition=ready pod -l app=weather-service -n agent-ns --timeout=120s 2>/dev/null
kubectl wait --for=condition=ready pod -l app=weather-tool -n tool-ns --timeout=120s 2>/dev/null

run "kubectl get pods -n agent-ns"

run "kubectl get pods -n tool-ns"

# ---------- Step 3: Use the kagenti UI ----------

echo ""
narrate "Step 3: Chat with the weather agent in the kagenti UI"
echo "  Open the kagenti UI, select weather-service in agent-ns, and send a message."
echo "  When done, press Enter here to see the token exchange logs."
prompt

# ---------- Step 4: Show token exchange logs ----------

narrate "Step 4: Token exchange logs"

run "kubectl logs -n kagenti-system -l app=token-exchange-service --tail=30 | grep -v 'JWKS refreshed'"

echo ""
echo "  To clean up:  bash deploy/11-weather-agent-demo.sh --cleanup"
echo ""
