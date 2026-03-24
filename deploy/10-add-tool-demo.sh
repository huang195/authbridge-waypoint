#!/usr/bin/env bash
# Live demo: add a new tool to the running system.
#
# Walks through adding "weather-tool" to tool-ns step by step.
# Each command is shown and waits for Enter before running.
#
# Prerequisites: system deployed via "make up" with tests passing.
# Usage: bash deploy/10-add-tool-demo.sh
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="waypoint-poc"
TOOL_NAME="weather-tool"
TOOL_SECRET="weather-secret"
KC_PORT=18080
PF_PID=""

# ---------- Demo helpers ----------

CYAN='\033[1;36m'
GREEN='\033[1;32m'
DIM='\033[2m'
RESET='\033[0m'

narrate() { echo -e "\n${CYAN}$*${RESET}"; }
prompt()  { echo -e "${DIM}press enter to continue...${RESET}"; read -r; }

# Show a command, wait for Enter, then run it.
run() {
  printf "\n${GREEN}\$ %s${RESET}" "$*"
  read -r
  eval "$@"
}

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl delete pod -n agent-ns curl-weather --force --grace-period=0 2>/dev/null || true
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

# ---------- Step 1: Register in Keycloak ----------

narrate "Step 1: Register weather-tool in Keycloak"

run "HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST '$KC_URL/admin/realms/$REALM/clients' \\
  -H 'Authorization: Bearer $ADMIN_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"clientId\": \"$TOOL_NAME\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"secret\": \"$TOOL_SECRET\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false
  }')
if [ \"\$HTTP_CODE\" = '201' ]; then echo '  Created client $TOOL_NAME';
elif [ \"\$HTTP_CODE\" = '409' ]; then echo '  Client $TOOL_NAME already exists (OK)';
else echo \"  WARNING: HTTP \$HTTP_CODE\"; fi"

EXCHANGE_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=token-exchange-service" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

run "HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' -X POST \\
  '$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models' \\
  -H 'Authorization: Bearer $ADMIN_TOKEN' \\
  -H 'Content-Type: application/json' \\
  -d '{
    \"name\": \"weather-tool-audience\",
    \"protocol\": \"openid-connect\",
    \"protocolMapper\": \"oidc-audience-mapper\",
    \"consentRequired\": false,
    \"config\": {
      \"included.client.audience\": \"$TOOL_NAME\",
      \"id.token.claim\": \"false\",
      \"access.token.claim\": \"true\"
    }
  }')
if [ \"\$HTTP_CODE\" = '201' ]; then echo '  Created audience mapper weather-tool-audience';
elif [ \"\$HTTP_CODE\" = '409' ]; then echo '  Mapper weather-tool-audience already exists (OK)';
else echo \"  WARNING: HTTP \$HTTP_CODE\"; fi"

# ---------- Step 2: Deploy ----------

narrate "Step 2: Deploy weather-tool in tool-ns (plain Deployment + Service)"

run "kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: weather-tool
  namespace: tool-ns
  labels:
    app: weather-tool
spec:
  replicas: 1
  selector:
    matchLabels:
      app: weather-tool
  template:
    metadata:
      labels:
        app: weather-tool
    spec:
      containers:
        - name: weather-tool
          image: curlimages/curl:latest
          command: ['sh', '-c']
          args:
            - |
              while true; do
                echo -e 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"weather\":\"sunny, 72F\",\"location\":\"San Francisco\"}' | nc -l -p 8080 > /dev/null
              done
          ports:
            - containerPort: 8080
          resources:
            requests:
              memory: 32Mi
              cpu: 25m
---
apiVersion: v1
kind: Service
metadata:
  name: weather-tool
  namespace: tool-ns
spec:
  selector:
    app: weather-tool
  ports:
    - port: 8080
      targetPort: 8080
YAML"

kubectl wait --for=condition=ready pod -l app=weather-tool -n tool-ns --timeout=60s 2>/dev/null

run "kubectl -n tool-ns get pods"

# ---------- Step 3: Test it ----------

narrate "Step 3: Call weather-tool through demo-agent — no code changes to the agent"

run "USER_TOKEN=\$(curl -sf -X POST '$KC_URL/realms/$REALM/protocol/openid-connect/token' \\
  -d 'grant_type=client_credentials' \\
  -d 'client_id=demo-agent' \\
  -d 'client_secret=agent-secret' | jq -r '.access_token')"

AGENT_URL="http://demo-agent.agent-ns.svc.cluster.local:8080/call/weather-tool"
kubectl delete pod -n agent-ns curl-weather --force --grace-period=0 2>/dev/null || true

run "kubectl run curl-weather -n agent-ns \\
  --image=curlimages/curl:latest \\
  --restart=Never \\
  --command -- sh -c \\
  \"curl -s -H 'Authorization: Bearer $USER_TOKEN' '$AGENT_URL'\""

kubectl wait --for=condition=ready pod/curl-weather -n agent-ns --timeout=30s 2>/dev/null || true
sleep 5

RESULT=$(kubectl logs -n agent-ns curl-weather 2>&1) || true
kubectl delete pod -n agent-ns curl-weather --force --grace-period=0 2>/dev/null || true

echo ""
echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"

narrate "Token exchange logs:"

run "kubectl logs -n kagenti-system -l app=token-exchange-service --tail=5"

# ---------- Cleanup ----------

echo ""
narrate "Cleaning up..."

kubectl delete deployment weather-tool -n tool-ns 2>/dev/null && echo "  Deleted deployment" || true
kubectl delete service weather-tool -n tool-ns 2>/dev/null && echo "  Deleted service" || true

WEATHER_UUID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=$TOOL_NAME" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

if [[ -n "$WEATHER_UUID" && "$WEATHER_UUID" != "null" ]]; then
  curl -sf -o /dev/null -X DELETE "$KC_URL/admin/realms/$REALM/clients/$WEATHER_UUID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" && echo "  Deleted Keycloak client" || true
fi

MAPPER_ID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.name=="weather-tool-audience") | .id')

if [[ -n "$MAPPER_ID" && "$MAPPER_ID" != "null" ]]; then
  curl -sf -o /dev/null -X DELETE "$KC_URL/admin/realms/$REALM/clients/$EXCHANGE_UUID/protocol-mappers/models/$MAPPER_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" && echo "  Deleted audience mapper" || true
fi

# ---------- Summary ----------

echo ""
echo "  Done. Added weather-tool with:"
echo "    1 Keycloak client  +  1 audience mapper  +  1 kubectl apply"
echo ""
echo "  Changed nothing: agent, exchange service, waypoint, policy, existing tools"
echo ""
