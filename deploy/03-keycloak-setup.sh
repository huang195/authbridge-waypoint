#!/usr/bin/env bash
# Post-import Keycloak setup for token exchange permissions.
# Realm JSON import creates clients but cannot configure fine-grained permissions.
# This script enables token-exchange permissions via the admin REST API.
#
# Prerequisites: Keycloak must be running with the waypoint-poc realm imported.
# Usage: KEYCLOAK_URL=http://localhost:18080 ./03-keycloak-setup.sh
set -euo pipefail

KC_URL="${KEYCLOAK_URL:-http://localhost:18080}"
REALM="waypoint-poc"
ADMIN_USER="${KC_ADMIN_USER:-admin}"
ADMIN_PASS="${KC_ADMIN_PASS:-admin}"

echo "=== Keycloak token exchange setup ==="
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

# Helper: get client UUID by clientId
get_client_uuid() {
  curl -sf "$KC_URL/admin/realms/$REALM/clients?clientId=$1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id'
}

EXCHANGE_UUID=$(get_client_uuid "token-exchange-service")
TOOL_UUID=$(get_client_uuid "echo-tool")
RM_UUID=$(get_client_uuid "realm-management")

echo "  token-exchange-service UUID: $EXCHANGE_UUID"
echo "  echo-tool UUID: $TOOL_UUID"
echo "  realm-management UUID: $RM_UUID"

# Step 1: Enable fine-grained permissions on echo-tool
echo ""
echo "1. Enabling fine-grained permissions on echo-tool..."
PERM_RESULT=$(curl -s -X PUT "$KC_URL/admin/realms/$REALM/clients/$TOOL_UUID/management/permissions" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}')

if echo "$PERM_RESULT" | jq -e '.scopePermissions["token-exchange"]' >/dev/null 2>&1; then
  TOKEN_EXCHANGE_PERM_ID=$(echo "$PERM_RESULT" | jq -r '.scopePermissions["token-exchange"]')
  echo "   OK — token-exchange permission ID: $TOKEN_EXCHANGE_PERM_ID"
else
  echo "   ERROR: $PERM_RESULT"
  echo "   Ensure Keycloak was started with --features=token-exchange,admin-fine-grained-authz:v1"
  exit 1
fi

# Step 2: Create a client policy for token-exchange-service
echo ""
echo "2. Creating client policy for token-exchange-service..."
POLICY_RESULT=$(curl -sf -X POST "$KC_URL/admin/realms/$REALM/clients/$RM_UUID/authz/resource-server/policy/client" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"allow-token-exchange-service\",
    \"description\": \"Allow token-exchange-service to perform token exchange\",
    \"clients\": [\"$EXCHANGE_UUID\"],
    \"logic\": \"POSITIVE\"
  }" 2>/dev/null || echo '{"id":"already-exists"}')

POLICY_ID=$(echo "$POLICY_RESULT" | jq -r '.id')
if [[ "$POLICY_ID" == "already-exists" || -z "$POLICY_ID" ]]; then
  # Policy may already exist — look it up
  POLICY_ID=$(curl -sf "$KC_URL/admin/realms/$REALM/clients/$RM_UUID/authz/resource-server/policy" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[] | select(.name=="allow-token-exchange-service") | .id')
fi
echo "   Policy ID: $POLICY_ID"

# Step 3: Associate the policy with the token-exchange permission
echo ""
echo "3. Associating policy with token-exchange permission..."
PERM_DETAILS=$(curl -sf "$KC_URL/admin/realms/$REALM/clients/$RM_UUID/authz/resource-server/permission/scope/$TOKEN_EXCHANGE_PERM_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN")

UPDATED_PERM=$(echo "$PERM_DETAILS" | jq --arg pid "$POLICY_ID" '. + {policies: [$pid]}')

curl -sf -X PUT "$KC_URL/admin/realms/$REALM/clients/$RM_UUID/authz/resource-server/permission/scope/$TOKEN_EXCHANGE_PERM_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$UPDATED_PERM" >/dev/null

echo "   OK — permission updated"

# Verify: test token exchange
echo ""
echo "=== Verifying token exchange ==="
AGENT_TOKEN=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=echo-agent&client_secret=agent-secret" | jq -r '.access_token')

EXCHANGE_RESULT=$(curl -s -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$AGENT_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=echo-tool" \
  -d "client_id=token-exchange-service" \
  -d "client_secret=exchange-secret")

if echo "$EXCHANGE_RESULT" | jq -e '.access_token' >/dev/null 2>&1; then
  EXCHANGED_AUD=$(echo "$EXCHANGE_RESULT" | jq -r '.access_token' | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.aud')
  echo "  Token exchange successful — exchanged token aud: $EXCHANGED_AUD"
else
  echo "  ERROR: Token exchange failed"
  echo "  $EXCHANGE_RESULT"
  exit 1
fi

echo ""
echo "=== Keycloak setup complete ==="
