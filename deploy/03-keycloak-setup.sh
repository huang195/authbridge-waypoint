#!/usr/bin/env bash
# Configure the kagenti Keycloak instance for the authbridge-waypoint PoC.
# Creates the kagenti realm, registers clients, and enables standard
# token exchange on the token-exchange-service client.
#
# Prerequisites: kagenti cluster running with Keycloak 26+ in the keycloak namespace.
# Usage: KEYCLOAK_URL=http://localhost:18080 ./03-keycloak-setup.sh
set -euo pipefail

KC_URL="${KEYCLOAK_URL:-http://localhost:18080}"
REALM="kagenti"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"

echo "=== Keycloak setup for authbridge-waypoint ==="
echo "  URL: $KC_URL"
echo "  Realm: $REALM"

# Get admin token
ADMIN_TOKEN=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=$ADMIN_USER&password=$ADMIN_PASS" | jq -r '.access_token')

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to get admin token"
  exit 1
fi
echo "  Admin token obtained"

# ---------- Step 1: Create realm ----------

echo ""
echo "1. Creating realm..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"realm\": \"$REALM\",
    \"enabled\": true,
    \"sslRequired\": \"none\",
    \"registrationAllowed\": false
  }")

if [[ "$HTTP_CODE" == "201" ]]; then
  echo "   Created realm '$REALM'"
elif [[ "$HTTP_CODE" == "409" ]]; then
  echo "   Realm '$REALM' already exists"
else
  echo "   WARNING: Unexpected status $HTTP_CODE creating realm"
fi

# ---------- Step 2: Create clients ----------

echo ""
echo "2. Creating clients..."

# Helper: create a client (idempotent — ignores 409)
create_client() {
  local client_id="$1"
  local secret="$2"
  local extra="${3:-}"

  local payload="{
    \"clientId\": \"$client_id\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"secret\": \"$secret\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false,
    \"defaultClientScopes\": [\"openid\"]
    $extra
  }"

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$KC_URL/admin/realms/$REALM/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$code" == "201" ]]; then
    echo "   Created client '$client_id'"
  elif [[ "$code" == "409" ]]; then
    echo "   Client '$client_id' already exists"
  else
    echo "   WARNING: Unexpected status $code creating client '$client_id'"
  fi
}

create_client "demo-agent" "agent-secret" ""
create_client "echo-tool" "tool-secret" ""
create_client "time-tool" "time-tool-secret" ""
create_client "token-exchange-service" "exchange-secret" \
  ', "attributes": {"standard.token.exchange.enabled": "true"}'

# Helper: get client UUID by clientId
get_client_uuid() {
  curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=$1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id'
}

# ---------- Step 3: Ensure standard token exchange is enabled ----------

echo ""
echo "3. Ensuring standard token exchange is enabled on token-exchange-service..."

# If the client already existed, the create_client call above won't update
# attributes, so we patch it explicitly.
# Only the requesting client (token-exchange-service) needs this attribute.
# The target audience client (echo-tool) does NOT need it.
CLIENT_UUID=$(get_client_uuid "token-exchange-service")
curl -sf -X PUT "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(curl -sf "$KC_URL/admin/realms/$REALM/clients/$CLIENT_UUID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | \
    jq '.attributes["standard.token.exchange.enabled"] = "true"')"
echo "   OK — enabled on token-exchange-service"

# ---------- Step 4: Add audience mappers ----------

echo ""
echo "4. Adding audience mappers..."

# Helper: add an audience mapper to a client (idempotent)
add_audience_mapper() {
  local target_client_uuid="$1"
  local mapper_name="$2"
  local audience_client="$3"

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$KC_URL/admin/realms/$REALM/clients/$target_client_uuid/protocol-mappers/models" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"$mapper_name\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"consentRequired\": false,
      \"config\": {
        \"included.client.audience\": \"$audience_client\",
        \"id.token.claim\": \"false\",
        \"access.token.claim\": \"true\"
      }
    }")

  if [[ "$code" == "201" ]]; then
    echo "   OK — created '$mapper_name'"
  elif [[ "$code" == "409" ]]; then
    echo "   '$mapper_name' already exists"
  else
    echo "   WARNING: Unexpected status $code creating '$mapper_name'"
  fi
}

AGENT_UUID=$(get_client_uuid "demo-agent")
EXCHANGE_UUID=$(get_client_uuid "token-exchange-service")

# Agent tokens include demo-agent as their primary audience (the token owner).
add_audience_mapper "$AGENT_UUID" "demo-agent-audience" "demo-agent"

# Agent tokens must also include token-exchange-service in the audience so the
# exchange service can present them as subject_token in the standard token exchange.
add_audience_mapper "$AGENT_UUID" "token-exchange-service-audience" "token-exchange-service"

# The kagenti platform client also needs token-exchange-service in its audience
# so the ext_authz can exchange tokens issued by the kagenti backend/UI.
KAGENTI_UUID=$(get_client_uuid "kagenti")
if [[ -n "$KAGENTI_UUID" && "$KAGENTI_UUID" != "null" ]]; then
  add_audience_mapper "$KAGENTI_UUID" "token-exchange-service-audience" "token-exchange-service"
fi

# token-exchange-service must list each tool as a valid audience so Keycloak
# allows exchanging tokens scoped to that tool.
add_audience_mapper "$EXCHANGE_UUID" "echo-tool-audience" "echo-tool"
add_audience_mapper "$EXCHANGE_UUID" "time-tool-audience" "time-tool"

# ---------- Verify: test token exchange ----------

echo ""
echo "=== Verifying token exchange ==="
AGENT_TOKEN=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=demo-agent&client_secret=agent-secret" | jq -r '.access_token')

EXCHANGE_RESULT=$(curl -s -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$AGENT_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=echo-tool" \
  -d "client_id=token-exchange-service" \
  -d "client_secret=exchange-secret")

if echo "$EXCHANGE_RESULT" | jq -e '.access_token' >/dev/null 2>&1; then
  PAYLOAD=$(echo "$EXCHANGE_RESULT" | jq -r '.access_token' | cut -d. -f2 | tr '_-' '/+' | awk '{while(length%4)$0=$0"=";print}' | base64 -d 2>/dev/null)
  EXCHANGED_AUD=$(echo "$PAYLOAD" | jq -r '.aud')
  echo "  Token exchange successful — exchanged token aud: $EXCHANGED_AUD"
else
  echo "  ERROR: Token exchange failed"
  echo "  $EXCHANGE_RESULT"
  exit 1
fi

echo ""
echo "=== Keycloak setup complete ==="
