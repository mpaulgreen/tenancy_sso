#!/bin/bash

# Token Rate Limit Test for Tenant A (Free Tier) - RH SSO Version
# Tests token consumption rate limiting using tenant-a-dev1@tenant-a.com
# Free tier limit: 1000 tokens per 1 minute

set -e

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Token Rate Limit Test - Tenant A (Free Tier)             ║"
echo "║  Identity Provider: Red Hat SSO (Keycloak)                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check required environment variables
if [ -z "$KEYCLOAK_URL" ] || [ -z "$CLIENT_SECRET" ] || [ -z "$MODEL_URL" ]; then
  echo -e "${RED}✗ ERROR: Required environment variables not set${NC}"
  echo ""
  echo "Please set the following environment variables:"
  echo "  export KEYCLOAK_URL=\$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')"
  echo "  export CLIENT_SECRET=\$(oc get secret keycloak-client-secret-openshift-client -n sso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -D)"
  echo "  export MODEL_URL=\"http://tenant-a.maas.\${CLUSTER_DOMAIN}/tenant-a-models/granite-3-1-8b-instruct-fp8\""
  echo ""
  exit 1
fi

# Prompt for tenant-a-dev1 password
echo "Enter password for tenant-a-dev1@tenant-a.com:"
read -s DEV1_PASSWORD
echo ""

# Get tenant-a-dev1 JWT token from RH SSO
echo "Obtaining JWT token for tenant-a-dev1@tenant-a.com from RH SSO..."
DEV1_TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=openshift" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=tenant-a-dev1" \
  -d "password=${DEV1_PASSWORD}" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

if [ -z "$DEV1_TOKEN" ] || [ "$DEV1_TOKEN" = "null" ]; then
  echo -e "${RED}✗ ERROR: Failed to obtain JWT token${NC}"
  echo "Please check your credentials and try again."
  exit 1
fi

echo -e "${GREEN}✓ Token obtained: ${DEV1_TOKEN:0:50}...${NC}"
echo ""

# Decode and verify token claims
echo "Verifying token claims..."
TOKEN_PAYLOAD=$(echo "$DEV1_TOKEN" | cut -d'.' -f2)
# Add padding if needed
case $((${#TOKEN_PAYLOAD} % 4)) in
  2) TOKEN_PAYLOAD="${TOKEN_PAYLOAD}==" ;;
  3) TOKEN_PAYLOAD="${TOKEN_PAYLOAD}=" ;;
esac

DECODED_PAYLOAD=$(echo "$TOKEN_PAYLOAD" | base64 -d 2>/dev/null)
GROUPS=$(echo "$DECODED_PAYLOAD" | jq -r '.groups // "unknown"')
USERNAME=$(echo "$DECODED_PAYLOAD" | jq -r '.preferred_username // "unknown"')
SUB=$(echo "$DECODED_PAYLOAD" | jq -r '.sub // "unknown"')
EMAIL=$(echo "$DECODED_PAYLOAD" | jq -r '.email // "unknown"')

echo "  Username: $USERNAME"
echo "  Email: $EMAIL"
echo "  Subject (sub): $SUB"
echo "  Groups claim: $GROUPS"

# RH SSO returns groups as an ARRAY (unlike IBM Verify which returns string)
echo -e "${YELLOW}  Note: RH SSO/Keycloak returns groups as an ARRAY${NC}"
echo -e "${YELLOW}        MaaS API will map this to tenant-a-free tier${NC}"
echo ""

# Run token rate limit test
echo "═══════════════════════════════════════════════════════════"
echo "Testing Token Rate Limits (Free tier: 1000 tokens/min)"
echo "User: tenant-a-dev1@tenant-a.com (tenant-a-developers group)"
echo "═══════════════════════════════════════════════════════════"
echo ""

TOTAL_TOKENS=0
REQUEST_COUNT=0
SUCCESS_COUNT=0
RATE_LIMITED_COUNT=0
START_TIME=$(date +%s)

# Make requests to consume tokens faster
# Target: ~200 tokens per request, 6-7 requests should hit the 1000 token limit
for i in {1..15}; do
  printf "Request %2d: " "$i"

  # Make request and capture HTTP code
  HTTP_CODE=$(curl -sk -w "%{http_code}" -o /tmp/token_test_$i.json \
    "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${DEV1_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "granite-3.1-8b-instruct-fp8",
      "messages": [{
        "role": "user",
        "content": "Write a detailed explanation about Kubernetes architecture, components, and deployment strategies. Include information about pods, services, ingress, and persistent volumes."
      }],
      "max_tokens": 150
    }')

  if [ "$HTTP_CODE" = "429" ]; then
    echo -e "${RED}✗ Rate Limited (HTTP 429)${NC} - Token limit reached after $TOTAL_TOKENS tokens"
    ((RATE_LIMITED_COUNT++))
    break
  elif [ "$HTTP_CODE" = "403" ]; then
    echo -e "${RED}✗ Forbidden (HTTP 403)${NC} - Authentication/Authorization error"
    echo "  Check that tenant-a-dev1 has access to tenant-a models"
    break
  elif [ "$HTTP_CODE" != "200" ]; then
    echo -e "${YELLOW}⚠ Error (HTTP $HTTP_CODE)${NC}"
    cat /tmp/token_test_$i.json | jq -r '.error.message // .message // "Unknown error"' 2>/dev/null || echo "No error message"
    break
  fi

  # Extract token usage from response
  TOKENS=$(jq -r '.usage.total_tokens // 0' /tmp/token_test_$i.json 2>/dev/null)

  if [ "$TOKENS" = "0" ]; then
    echo -e "${YELLOW}⚠ Error - No token usage in response${NC}"
    break
  fi

  TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS))
  ((REQUEST_COUNT++))
  ((SUCCESS_COUNT++))

  echo -e "${GREEN}✓ Success${NC} - Used $TOKENS tokens (Total: $TOTAL_TOKENS)"

  # Check if we've exceeded the limit (should be caught by Limitador)
  if [ $TOTAL_TOKENS -gt 1000 ]; then
    echo -e "  ${YELLOW}Warning: Total tokens ($TOTAL_TOKENS) exceeded 1000${NC}"
  fi

  # No sleep - generate tokens as fast as possible to trigger the limit
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Cleanup temp files
rm -f /tmp/token_test_*.json

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Token Rate Limit Test Results:"
echo "═══════════════════════════════════════════════════════════"
echo "  Identity Provider: Red Hat SSO (Keycloak)"
echo "  User: tenant-a-dev1@tenant-a.com"
echo "  Tier: Free (1000 tokens/min)"
echo "  Time elapsed: ${ELAPSED}s"
echo ""
echo "  Successful requests: $SUCCESS_COUNT"
echo "  Rate limited requests: $RATE_LIMITED_COUNT"
echo "  Total tokens consumed: $TOTAL_TOKENS"
echo ""
echo "Expected behavior:"
echo "  First 5-6 requests: Success (~200 tokens each)"
echo "  After ~1000 tokens: Rate limited (HTTP 429)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Validate test results
if [ $RATE_LIMITED_COUNT -gt 0 ] && [ $TOTAL_TOKENS -ge 800 ] && [ $TOTAL_TOKENS -le 1200 ]; then
  echo -e "${GREEN}✓ Test PASSED: Token rate limiting working correctly${NC}"
  echo ""
  echo "Summary:"
  echo "  ✓ Rate limiting enforced after ~${TOTAL_TOKENS} tokens"
  echo "  ✓ Within expected range (800-1200 tokens)"
  echo "  ✓ HTTP 429 received when limit exceeded"
  exit 0
else
  echo -e "${RED}✗ Test FAILED: Unexpected behavior${NC}"
  echo ""
  echo "Issues detected:"
  if [ $RATE_LIMITED_COUNT -eq 0 ]; then
    echo "  ✗ No rate limiting occurred (expected HTTP 429)"
  fi
  if [ $TOTAL_TOKENS -lt 800 ] || [ $TOTAL_TOKENS -gt 1200 ]; then
    echo "  ✗ Total tokens ($TOTAL_TOKENS) outside expected range (800-1200)"
  fi
  echo ""
  echo "Troubleshooting:"
  echo "  1. Check if TokenRateLimitPolicy is applied:"
  echo "     oc get tokenratelimitpolicy -n openshift-ingress"
  echo "  2. Check if policy is enforced:"
  echo "     oc describe tokenratelimitpolicy tenant-a-gateway-token-rate-limits -n openshift-ingress"
  echo "  3. Check Limitador logs:"
  echo "     oc logs -n kuadrant-system -l app=limitador --tail=50"
  echo "  4. Verify JWT token claims (groups should be array):"
  echo "     echo \"\$DEV1_TOKEN\" | cut -d'.' -f2 | base64 -D 2>/dev/null | jq '.'"
  exit 1
fi
