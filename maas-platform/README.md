# Multi-Tenant MaaS Platform Deployment Guide

## Overview

This directory contains Kubernetes manifests for deploying a multi-tenant Model-as-a-Service (MaaS) platform using **Per-Tenant Gateway**. This approach provides the strongest isolation between tenants by giving each tenant a dedicated Gateway resource.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Red Hat Single Sign-On (Keycloak)                       │
│  • Tenant A Users: alice@tenant-a.com (admin)               │
│                    tenant-a-dev1@tenant-a.com (developer)   │
│                    tenant-a-ml-eng1@tenant-a.com (ML eng)   │
│  • Tenant B Users: bob@tenant-b.com (admin)                 │
│  • Custom Attribute: accountId (tenant-a or tenant-b)       │
│  • Groups: tenant-a-admins, tenant-b-admins, etc.           │
└──────────────────────┬──────────────────────────────────────┘
                       │ JWT with accountId + groups claims
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              Per-Tenant Gateways (Option 3)                  │
│  ┌────────────────────┐       ┌────────────────────┐        │
│  │ tenant-a-gateway   │       │ tenant-b-gateway   │        │
│  │ tenant-a.maas.     │       │ tenant-b.maas.     │        │
│  │ CLUSTER_DOMAIN     │       │ CLUSTER_DOMAIN     │        │
│  └──────┬─────────────┘       └──────┬─────────────┘        │
│         │                             │                      │
│         │ AuthPolicy                  │ AuthPolicy           │
│         │ RateLimitPolicy             │ RateLimitPolicy      │
│         │ TokenRateLimitPolicy        │ TokenRateLimitPolicy │
│         ▼                             ▼                      │
│  ┌────────────────────┐       ┌────────────────────┐        │
│  │ tenant-a-models    │       │ tenant-b-models    │        │
│  │ • Granite 3.1 8B   │       │ • (No models yet)  │        │
│  └────────────────────┘       └────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                  Shared MaaS API                             │
│  • Tier lookup: /v1/tiers/lookup                            │
│  • Model discovery across all tenants                       │
│  • Service account token generation                         │
└─────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
maas-platform/
├── README.md                           # This file
├── cluster-admin/                      # Cluster admin resources
│   ├── 01-kuadrant-setup.yaml         # Kuadrant, OpenShift AI Gateway
│   ├── 02-maas-api.yaml               # Shared MaaS API
│   ├── 03-tenant-namespaces.yaml      # Tenant namespaces, quotas
│   ├── 04-tenant-a-gateway.yaml       # Tenant A Gateway (cluster-admin)
│   ├── 05-tenant-b-gateway.yaml       # Tenant B Gateway (cluster-admin)
│   ├── 06-tenant-a-policies.yaml      # Tenant A Auth & Rate Limit Policies (cluster-admin)
│   └── 07-tenant-b-policies.yaml      # Tenant B Auth & Rate Limit Policies (cluster-admin)
└── tenant-a/                           # Tenant A resources (tenant-admin)
    └── 00-tenant-a-model.yaml         # LLMInferenceService (Granite 3.1 8B)
└── tenant-b/                           # Tenant B resources (tenant-admin)
    └── 00-tenant-b-model.yaml         # LLMInferenceService (template)
```

**Important Architecture Note:**
- **AuthPolicy and RateLimitPolicy MUST target the Gateway**  to enable proper rate limiting enforcement
- **Policies MUST be in openshift-ingress namespace** (same namespace as Gateway)
- **Cluster admins deploy all policies** - tenant admins cannot create policies in openshift-ingress namespace
- **Tenant admins only deploy models** (LLMInferenceService) in their tenant namespaces

## Prerequisites

### Cluster Requirements

1. **OpenShift 4.19+** with cluster-admin access
2. **Red Hat OpenShift AI (RHOAI) 3.0.0+** installed
3. **Kuadrant Operator** installed
4. **GPU nodes** available for model inference (optional but recommended)

### Identity Provider Setup

1. **Red Hat SSO (Keycloak)** instance deployed in `sso` namespace
2. **maas-platform realm** created in Keycloak
3. **OpenShift OAuth client** created with protocol mappers (groups, accountId, email)
4. **Custom attribute** `accountId` configured for users
5. **Groups** created in Keycloak (via Admin Console):
   - `tenant-a-admins` (contains: alice@tenant-a.com)
   - `tenant-a-developers` (contains: tenant-a-dev1@tenant-a.com)
   - `tenant-a-ml-engineers` (contains: tenant-a-ml-eng1@tenant-a.com)
   - `tenant-b-admins` (contains: bob@tenant-b.com)
6. **Users configured** with `accountId` custom attribute:
   - alice@tenant-a.com → accountId: tenant-a
   - tenant-a-dev1@tenant-a.com → accountId: tenant-a
   - tenant-a-ml-eng1@tenant-a.com → accountId: tenant-a
   - bob@tenant-b.com → accountId: tenant-b

**Note**: RH SSO returns JWT groups claim as an **ARRAY** (e.g., `["tenant-a-admins"]`), unlike IBM Verify which returns a string.

For detailed RH SSO setup, see: [tenant_admin_rbac_implementation_rhsso.md](../tenant_admin_rbac_implementation_rhsso.md#1-red-hat-sso-setup-for-tenant-admin-users)

### Tenant RBAC Setup

Before deploying MaaS platform resources, ensure tenant RBAC is configured:

1. **Tenant namespaces created** (done by cluster admin):
   - `tenant-a-models`
   - `tenant-b-models`

2. **tenant-admin ClusterRole created** (done by cluster admin)

3. **OpenShift Group objects created** (done by cluster admin):
   - `tenant-a-admins`
   - `tenant-a-developers`
   - `tenant-a-ml-engineers`
   - `tenant-b-admins`

4. **RoleBindings created** (done by cluster admin):
   - `tenant-a-admins-binding` in `tenant-a-models` namespace
   - `tenant-b-admins-binding` in `tenant-b-models` namespace

For detailed RBAC setup, see: [tenant_admin_rbac_implementation_rhsso.md](../tenant_admin_rbac_implementation_rhsso.md)

## Deployment Steps

### Phase 1: Cluster Admin Setup

**Role**: Cluster Administrator (system:admin or kubeadmin)

**Objective**: Deploy shared infrastructure and create tenant namespaces

#### Step 1.1: Set Environment Variables

```bash
# Set cluster domain
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

# Verify
echo "Cluster domain: ${CLUSTER_DOMAIN}"
# Example output: apps.minai.kni.syseng.devcluster.openshift.com
```

#### Step 1.2: Deploy Kuadrant Setup

```bash
# Login as cluster admin
oc login -u kubeadmin

# Apply Kuadrant setup
oc apply -f cluster-admin/01-kuadrant-setup.yaml
```

**What this creates:**
- `kuadrant-system` namespace
- `Kuadrant` CR (creates Authorino and Limitador)
- `openshift-ai-inference` Gateway (required by RHOAI)

**Verification:**

```bash
# Check Kuadrant components
oc get kuadrant -n kuadrant-system
oc get pods -n kuadrant-system

# Check OpenShift AI Gateway
oc get gateway openshift-ai-inference -n openshift-ingress

# Wait for all pods to be Running
oc wait --for=condition=ready pod --all -n kuadrant-system --timeout=300s
```

#### Step 1.3: Deploy MaaS API

```bash
# Apply MaaS API with environment variable substitution
cat cluster-admin/02-maas-api.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `maas-api` namespace
- `maas-api` ServiceAccount
- `maas-api` ClusterRole and ClusterRoleBinding
- `tier-to-group-mapping` ConfigMap (multi-tenant tier definitions)
- `maas-api` Service
- `maas-api` Deployment

**Verification:**

```bash
# Check MaaS API deployment
oc get deployment -n maas-api
oc get pods -n maas-api

# Wait for deployment
oc wait --for=condition=available deployment/maas-api -n maas-api --timeout=300s

# Check MaaS API health
oc exec -n maas-api deployment/maas-api -- curl -s http://localhost:8080/health
# Expected: {"status":"healthy"}
```

#### Step 1.4: Create Tenant Namespaces and Quotas

```bash
# Apply tenant namespaces and resource quotas
oc apply -f cluster-admin/03-tenant-namespaces.yaml
```

**What this creates:**
- `tenant-a-models` namespace with labels and Pod Security Standards
- `tenant-b-models` namespace with labels and Pod Security Standards
- ResourceQuota for tenant-a (100 CPU, 500Gi memory, 10 GPUs)
- ResourceQuota for tenant-b (50 CPU, 250Gi memory, 5 GPUs)
- NetworkPolicies (optional, commented out by default)

**Verification:**

```bash
# Check namespaces
oc get namespaces -l app.kubernetes.io/part-of=model-as-a-service

# Check resource quotas
oc describe resourcequota -n tenant-a-models
oc describe resourcequota -n tenant-b-models

# Check Pod Security Standards
oc get namespace tenant-a-models -o yaml | grep pod-security
oc get namespace tenant-b-models -o yaml | grep pod-security
```

#### Step 1.5: Deploy Tenant A Gateway

**Note:** Gateways are created in the `openshift-ingress` namespace and require cluster-admin permissions. Tenant admins cannot create their own gateways.

```bash
# Deploy dedicated Gateway for Tenant A
cat cluster-admin/04-tenant-a-gateway.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `tenant-a-gateway` Gateway in `openshift-ingress` namespace
- Hostname: `tenant-a.maas.${CLUSTER_DOMAIN}`
- HTTP (port 80) and HTTPS (port 443) listeners

**Verification:**

```bash
# Check Gateway status
oc get gateway tenant-a-gateway -n openshift-ingress

# Check Gateway details
oc describe gateway tenant-a-gateway -n openshift-ingress

# Check hostname
oc get gateway tenant-a-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}'
# Expected: tenant-a.maas.CLUSTER_DOMAIN
```

#### Step 1.6: Deploy Tenant B Gateway

```bash
# Deploy dedicated Gateway for Tenant B
cat cluster-admin/05-tenant-b-gateway.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `tenant-b-gateway` Gateway in `openshift-ingress` namespace
- Hostname: `tenant-b.maas.${CLUSTER_DOMAIN}`
- HTTP (port 80) and HTTPS (port 443) listeners

**Verification:**

```bash
# Check Gateway status
oc get gateway tenant-b-gateway -n openshift-ingress

# Check hostname
oc get gateway tenant-b-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}'
# Expected: tenant-b.maas.CLUSTER_DOMAIN
```

#### Step 1.7: Deploy Tenant A Policies (AuthPolicy and RateLimitPolicy)

**CRITICAL:** Policies MUST target the Gateway and MUST be in the openshift-ingress namespace to enable proper rate limiting enforcement.

```bash
# Set RH SSO tenant
export KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath="{.spec.host}")  # test-maas"  # Replace with your RH SSO tenant

# Deploy Gateway-level policies for Tenant A
cat cluster-admin/06-tenant-a-policies.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `tenant-a-gateway-auth-policy` AuthPolicy in `openshift-ingress` namespace
  - JWT validation using RH SSO issuer
  - Tenant validation (groups must start with "tenant-a-")
  - Tier lookup from MaaS API
  - User identity injection (tier, userid, username, groups)
- `tenant-a-gateway-rate-limits` RateLimitPolicy in `openshift-ingress` namespace
  - Free tier: 5 req/2m
  - Premium tier: 20 req/2m
  - Enterprise tier: 50 req/2m
- `tenant-a-gateway-token-rate-limits` TokenRateLimitPolicy in `openshift-ingress` namespace
  - Free tier: 1000 tokens/1m
  - Premium tier: 50000 tokens/1m
  - Enterprise tier: 100000 tokens/1m

**Verification:**

```bash
# Check AuthPolicy status
oc get authpolicy -n openshift-ingress
oc describe authpolicy tenant-a-gateway-auth-policy -n openshift-ingress

# Check RateLimitPolicy status
oc get ratelimitpolicy -n openshift-ingress
oc describe ratelimitpolicy tenant-a-gateway-rate-limits -n openshift-ingress

# Check TokenRateLimitPolicy status
oc get tokenratelimitpolicy -n openshift-ingress
oc describe tokenratelimitpolicy tenant-a-gateway-token-rate-limits -n openshift-ingress
```

**Troubleshooting: AuthPolicy shows ACCEPTED: False**

If the AuthPolicy shows `ACCEPTED: False` with message `[Gateway API provider (istio / envoy gateway)] is not installed`, this indicates a timing issue where Kuadrant Operator started before Istio was fully ready.

**Fix:**
```bash
# Restart Kuadrant components to trigger re-detection of Istio
oc delete pod -n kuadrant-system -l app.kubernetes.io/name=authorino
oc delete pod -n kuadrant-system -l app=limitador
oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator

# Wait 30 seconds for reconciliation
sleep 30

# Verify AuthPolicy is now accepted
oc get authpolicy -n openshift-ingress -o wide
# Expected: ACCEPTED: True, ENFORCED: False (until routes are created)
```

**Note:** `ENFORCED: False` is expected at this stage. The AuthPolicy will show `ENFORCED: True` once models are deployed and HTTPRoutes are created that reference this Gateway.

#### Step 1.8: Deploy Tenant B Policies (AuthPolicy and RateLimitPolicy)

```bash
# Deploy Gateway-level policies for Tenant B
cat cluster-admin/07-tenant-b-policies.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `tenant-b-gateway-auth-policy` AuthPolicy in `openshift-ingress` namespace
- `tenant-b-gateway-rate-limits` RateLimitPolicy in `openshift-ingress` namespace
- `tenant-b-gateway-token-rate-limits` TokenRateLimitPolicy in `openshift-ingress` namespace

**Verification:**

```bash
# Check policies for Tenant B
oc get authpolicy tenant-b-gateway-auth-policy -n openshift-ingress
oc get ratelimitpolicy tenant-b-gateway-rate-limits -n openshift-ingress
oc get tokenratelimitpolicy tenant-b-gateway-token-rate-limits -n openshift-ingress
```

#### Step 1.9: Verify RBAC Setup

Ensure tenant RBAC is configured (see Prerequisites section):

```bash
# Verify tenant-admin ClusterRole exists
oc get clusterrole tenant-admin

# Verify Groups exist
oc get group tenant-a-admins
oc get group tenant-b-admins

# Verify RoleBindings exist
oc get rolebinding -n tenant-a-models tenant-a-admins-binding
oc get rolebinding -n tenant-b-models tenant-b-admins-binding

# Test tenant admin permissions (as cluster admin)
oc auth can-i create pods -n tenant-a-models --as alice@tenant-a.com --as-group=tenant-a-admins
# Expected: yes

oc auth can-i create pods -n tenant-b-models --as alice@tenant-a.com --as-group=tenant-a-admins
# Expected: no (cross-tenant access blocked)
```

**Cluster Admin Setup Complete!** 

---

### Phase 2: Tenant A Deployment

**Role**: Tenant A Administrator (alice@tenant-a.com)

**Objective**: Deploy Granite 3.1 8B model for Tenant A

**Note**: The dedicated Gateway and policies for Tenant A were already created by cluster admin in Phase 1 (Steps 1.5 and 1.7).

#### Step 2.1: Login as Tenant A Admin

```bash
# Login to OpenShift console via browser
# Select "rhsso" identity provider
# Login as: alice@tenant-a.com

# Get token from OpenShift console:
# Click your username → Copy login command → Display Token

# Login via CLI
oc login --token=<alice-token> --server=https://api.<cluster-domain>:6443

# Verify identity
oc whoami
# Expected: alice@tenant-a.com

# Verify accessible projects
oc get projects
# Expected: Shows tenant-a-* projects only
```

#### Step 2.2: Set Environment Variables

```bash
export CLUSTER_DOMAIN=$(oc whoami --show-server | sed 's/.*api\.\(.*\):6443/apps.\1/')
export KEYCLOAK_URL="keycloak-sso.${CLUSTER_DOMAIN}"

# Verify
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Keycloak URL: ${KEYCLOAK_URL}"
```

#### Step 2.3: Deploy Model (LLMInferenceService)

Deploy the Granite 3.1 8B Instruct model using vLLM runtime:

```bash
# Deploy the model with environment variable substitution
cat tenant-a/00-tenant-a-model.yaml | envsubst | oc apply -f -
```

**What this creates:**
- `granite-3-1-8b-instruct-fp8` LLMInferenceService in `tenant-a-models` namespace
- vLLM inference server with FP8 quantization
- Automatic creation of predictor service and HTTPRoute
- Model accessible via `tenant-a-gateway`

**Verification:**

```bash
# Check LLMInferenceService status
oc get llminferenceservice -n tenant-a-models

# Wait for LLMInferenceService to become Ready
# The Gateway-level AuthPolicy was already deployed by cluster admin in Step 1.7
oc wait --for=condition=Ready llminferenceservice/granite-3-1-8b-instruct-fp8 \
  -n tenant-a-models --timeout=5m

# Check automatically created resources
oc get httproute -n tenant-a-models
# Expected: granite-3-1-8b-instruct-fp8-kserve-route

oc get services -n tenant-a-models
# Expected: granite-3-1-8b-instruct-fp8-kserve-workload-svc

oc get deployment -n tenant-a-models
# Expected: granite-3-1-8b-instruct-fp8-kserve
```

**Note:** The LLMInferenceService should become `READY: True` shortly after deployment since the Gateway-level AuthPolicy was already applied by the cluster admin in Phase 1.

#### Step 2.4: End-to-End Testing for Tenant A

##### 2.4.1: Get Alice's JWT Token

```bash
# Set RH SSO OAuth credentials
export CLIENT_ID="<your-oauth-client-id>"
export CLIENT_SECRET="<your-oauth-client-secret>"

# Get Alice's JWT token from RH SSO using Resource Owner Password Credentials (ROPC) flow
export ALICE_TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=alice@tenant-a.com" \
  -d "password=password123" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

echo "Alice's token obtained: ${ALICE_TOKEN:0:50}..."
```

##### 2.4.2: Decode and Verify Alice's Token Claims

```bash
# Decode the JWT payload to inspect claims
echo "$ALICE_TOKEN" | cut -d'.' -f2 | python3 -c "import base64, json, sys; print(json.dumps(json.loads(base64.urlsafe_b64decode(sys.stdin.read() + '===')), indent=2))"
```

**Expected claims for alice@tenant-a.com (RH SSO/Keycloak):**
```json
{
  "exp": 1765478537,
  "iat": 1765478237,
  "jti": "ac318b88-e921-4508-86c9-0fd94e8856fe",
  "iss": "https://keycloak-sso.apps.tenantai.kni.syseng.devcluster.openshift.com/auth/realms/maas-platform",
  "sub": "29abe4ac-efd5-4254-996f-8bcbd19c5424",
  "typ": "Bearer",
  "azp": "openshift",
  "session_state": "8c2ffc41-b2ab-4969-a6d8-729e7cafd5b1",
  "scope": "openid profile email",
  "sid": "8c2ffc41-b2ab-4969-a6d8-729e7cafd5b1",
  "accountId": "tenant-a",
  "email_verified": true,
  "name": "Alice Admin",
  "groups": [
    "tenant-a-admins"
  ],
  "preferred_username": "alice@tenant-a.com",
  "given_name": "Alice",
  "family_name": "Admin",
  "email": "alice@tenant-a.com"
}
```

**Key claims to verify:**
- `groups`: **ARRAY** `["tenant-a-admins"]` (RH SSO returns array, not string like IBM Verify)
- `preferred_username`: "alice" (or "alice@tenant-a.com" depending on configuration)
- `email`: "alice@tenant-a.com"
- `accountId`: "tenant-a" (custom user attribute)
- `sub`: UUID from Keycloak (not username)
- `iss`: Matches the issuerUrl in AuthPolicy (`https://<keycloak-url>/auth/realms/maas-platform`)
- `exp`: Token expiration timestamp (usually 2 hours from `iat`)

**CRITICAL DIFFERENCE: RH SSO vs IBM Verify:**
- **RH SSO**: `groups` is an **ARRAY**: `["tenant-a-admins"]`
- **IBM Verify**: `groups` is a **STRING**: `"tenant-a-admins"`

##### 2.4.3: Test Model Endpoints with Alice's Token

Set the model URL:
```bash
export MODEL_URL="http://tenant-a.maas.${CLUSTER_DOMAIN}/tenant-a-models/granite-3-1-8b-instruct-fp8"
```

**Test 1: List models**

```bash
echo "Test 2: /v1/models endpoint..."
curl -k "${MODEL_URL}/v1/models" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" | jq .
```

**Expected result:**
```json
{
  "object": "list",
  "data": [
    {
      "id": "granite-3.1-8b-instruct-fp8",
      "object": "model",
      "created": 1765213283,
      "owned_by": "vllm",
      "root": "/mnt/models",
      "parent": null,
      "max_model_len": 4096
    }
  ]
}
```

**Test 2: Chat completions**

```bash
echo "Test 3: /v1/chat/completions endpoint..."
curl -k "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.1-8b-instruct-fp8",
    "messages": [
      {
        "role": "user",
        "content": "Say hello in one sentence"
      }
    ],
    "max_tokens": 50
  }' | jq .
```

**Expected result:**
```json
{
  "id": "cmpl-abc123",
  "object": "chat.completion",
  "created": 1765213500,
  "model": "granite-3.1-8b-instruct-fp8",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I assist you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 10,
    "total_tokens": 22
  }
}
```

##### 2.4.4: Get Bob's JWT Token

```bash
# Get Bob's (tenant-b user) JWT token from RH SSO
export BOB_TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=bob@tenant-b.com" \
  -d "password=<bob-password>" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

echo "Bob's token obtained: ${BOB_TOKEN:0:50}..."
```

##### 2.4.5: Decode and Verify Bob's Token Claims

```bash
# Decode Bob's JWT payload
echo "$BOB_TOKEN" | cut -d'.' -f2 | python3 -c "import base64, json, sys; print(json.dumps(json.loads(base64.urlsafe_b64decode(sys.stdin.read() + '===')), indent=2))"
```

**Expected claims for bob@tenant-b.com (RH SSO/Keycloak):**
```json
{
  "exp": 1765478763,
  "iat": 1765478463,
  "jti": "aa43a57d-5b36-460d-a226-e97ca5349792",
  "iss": "https://keycloak-sso.apps.tenantai.kni.syseng.devcluster.openshift.com/auth/realms/maas-platform",
  "sub": "f5216fc2-7646-4a3f-a600-7cb6108597c6",
  "typ": "Bearer",
  "azp": "openshift",
  "session_state": "8dbc9fc1-f6d1-42ee-a187-cb008f3f7a9a",
  "scope": "openid profile email",
  "sid": "8dbc9fc1-f6d1-42ee-a187-cb008f3f7a9a",
  "accountId": "tenant-b",
  "email_verified": true,
  "name": "bob admin",
  "groups": [
    "tenant-b-admins"
  ],
  "preferred_username": "bob@tenant-b.com",
  "given_name": "bob",
  "family_name": "admin",
  "email": "bob@tenant-b.com"
}
```

**Key claims to verify:**
- `groups`: **ARRAY** `["tenant-b-admins"]` (starts with "tenant-b-", NOT "tenant-a-")
- `preferred_username`: "bob" (or "bob@tenant-b.com" depending on configuration)
- `email`: "bob@tenant-b.com"
- `accountId`: "tenant-b" (custom user attribute)
- `sub`: UUID from Keycloak - Different from Alice's sub (different user)

##### 2.4.6: Test Rate Limiting (Request-based)

The RateLimitPolicy enforces request limits based on user tier:
- **Free tier**: 5 requests per 2 minutes
- **Premium tier**: 20 requests per 2 minutes
- **Enterprise tier**: 50 requests per 2 minutes

Alice is in the `tenant-a-admins` group, which maps to the **enterprise tier** (50 req/2min).

```bash
echo "Testing Request Rate Limits (Enterprise tier: 50 req/2min)..."
echo "Making 55 rapid requests..."

SUCCESS=0
RATE_LIMITED=0

for i in {1..55}; do
  printf "Request %2d: " "$i"

  HTTP_CODE=$(curl -sk -w "%{http_code}" -o /dev/null \
    "${MODEL_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ALICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "granite-3.1-8b-instruct-fp8",
      "messages": [{"role": "user", "content": "test"}],
      "max_tokens": 5
    }')

  if [ "$HTTP_CODE" = "200" ]; then
    echo "Success (HTTP 200)"
    ((SUCCESS++))
  elif [ "$HTTP_CODE" = "429" ]; then
    echo "Rate Limited (HTTP 429)"
    ((RATE_LIMITED++))
  else
    echo "Error (HTTP $HTTP_CODE)"
  fi

  sleep 0.5
done

echo ""
echo "═══════════════════════════════════════"
echo "Results:"
echo "  Successful requests: $SUCCESS"
echo "  Rate limited: $RATE_LIMITED"
echo ""
echo "Expected for Enterprise tier:"
echo "  First ~50 requests: Success"
echo "  Remaining ~5 requests: Rate limited (HTTP 429)"
echo "═══════════════════════════════════════"
```

##### 2.4.7: Test Token Rate Limiting (Usage-based)

The TokenRateLimitPolicy enforces token consumption limits:
- **Free tier**: 1,000 tokens per 1 minute
- **Premium tier**: 50,000 tokens per 1 minute
- **Enterprise tier**: 100,000 tokens per 1 minute

**For this test, we'll use `tenant-a-dev1@tenant-a.com` (free tier: 1000 tokens/min) to make it easier to trigger the limit.**

A comprehensive test script is provided: `test-token-rate-limit.sh`

**Run the automated test:**

```bash
# Ensure environment variables are set
export KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath="{.spec.host}")  # test-maas"
export CLIENT_ID="<your-oauth-client-id>"
export CLIENT_SECRET="<your-oauth-client-secret>"
export CLUSTER_DOMAIN="apps.minai.kni.syseng.devcluster.openshift.com"
export MODEL_URL="http://tenant-a.maas.${CLUSTER_DOMAIN}/tenant-a-models/granite-3-1-8b-instruct-fp8"

# Run the test script
./test-token-rate-limit.sh
```

The script will:
1. Prompt for tenant-a-dev1 password (secure input)
2. Obtain JWT token from RH SSO
3. Verify token claims (username, subject, groups)
4. Make rapid requests to consume ~1000 tokens
5. Verify HTTP 429 is returned when limit is exceeded
6. Report detailed test results with pass/fail status

**Expected output:**
```
╔════════════════════════════════════════════════════════════╗
║  Token Rate Limit Test - Tenant A (Free Tier)             ║
╚════════════════════════════════════════════════════════════╝

Enter password for tenant-a-dev1@tenant-a.com:

Obtaining JWT token for tenant-a-dev1@tenant-a.com...
Token obtained: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNlcn...

Verifying token claims...
  Username: tenant-a-dev1@tenant-a.com
  Subject (sub): 645007TB4N
  Groups claim: 20
  Note: Groups claim format varies by RH SSO configuration
        MaaS API will map this to tenant-a-free tier

═══════════════════════════════════════════════════════════
Testing Token Rate Limits (Free tier: 1000 tokens/min)
User: tenant-a-dev1@tenant-a.com (tenant-a-developers group)
═══════════════════════════════════════════════════════════

Request  1: Success - Used 236 tokens (Total: 236)
Request  2: Success - Used 236 tokens (Total: 472)
Request  3: Success - Used 236 tokens (Total: 708)
Request  4: Success - Used 236 tokens (Total: 944)
Request  5: Success - Used 236 tokens (Total: 1180)
  Warning: Total tokens (1180) exceeded 1000
Request  6: Rate Limited (HTTP 429) - Token limit reached after 1180 tokens

═══════════════════════════════════════════════════════════
Token Rate Limit Test Results:
═══════════════════════════════════════════════════════════
  User: tenant-a-dev1@tenant-a.com
  Tier: Free (1000 tokens/min)
  Time elapsed: 16s

  Successful requests: 5
  Rate limited requests: 1
  Total tokens consumed: 1180

Expected behavior:
  First 5-6 requests: Success (~200 tokens each)
  After ~1000 tokens: Rate limited (HTTP 429)
═══════════════════════════════════════════════════════════

Test PASSED: Token rate limiting working correctly

Summary:
  Rate limiting enforced after ~1180 tokens
  Within expected range (800-1200 tokens)
  HTTP 429 received when limit exceeded
```

##### 2.4.8: Test Bob's Access to Tenant A (Should Be Denied)

**Test 3: Bob accessing /v1/models (should fail)**

```bash
echo "Test 5: Bob accessing /v1/models endpoint..."
curl -v -k "${MODEL_URL}/v1/models" \
  -H "Authorization: Bearer ${BOB_TOKEN}"
```

**Expected result:**
- HTTP Status Code: `403 Forbidden`
- Header: `x-ext-auth-reason: Unauthorized`
0
**Test 4: Bob accessing /v1/chat/completions (should fail)**

```bash
echo "Test 6: Bob accessing /v1/chat/completions endpoint..."
curl -v -k "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${BOB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.1-8b-instruct-fp8",
    "messages": [{"role": "user", "content": "Say hello"}],
    "max_tokens": 50
  }'
```

**Expected result:**
- HTTP Status Code: `403 Forbidden`
- Header: `x-ext-auth-reason: Unauthorized`

##### Test Summary

**Alice (tenant-a-admins) - All tests should succeed:**
| Test | Endpoint | Expected Result |
|------|----------|----------------|
| 1 | `/v1/models` | 200 OK (model list) |
| 2 | `/v1/chat/completions` | 200 OK (AI response) |

**Bob (tenant-b-admins) - All tests should fail:**
| Test | Endpoint | Expected Result |
|------|----------|----------------|
| 3 | `/v1/models` | 403 Forbidden (Unauthorized) |
| 4 | `/v1/chat/completions` | 403 Forbidden (Unauthorized) |

**Why Bob is denied access:**

The AuthPolicy contains a Rego rule that validates the tenant:

```rego
package tenant_validation

# Allow if groups claim starts with tenant-a-
allow {
  startswith(input.auth.identity.groups, "tenant-a-")
}
```

- Alice's `groups` claim: "tenant-a-admins"] → Starts with "tenant-a-" → **Allowed**
- Bob's `groups` claim: "tenant-b-admins"] → Does NOT start with "tenant-a-" → **Denied**

This ensures strict tenant isolation at the authorization layer.

**Tenant A Deployment Complete!** 

---

### Phase 3: Tenant B Deployment

**Role**: Tenant B Administrator (bob@tenant-b.com)

**Objective**: Deploy model for Tenant B

**Note**: The dedicated Gateway and policies for Tenant B were already created by cluster admin in Phase 1 (Steps 1.6 and 1.8).

#### Step 3.1: Login as Tenant B Admin

```bash
# Login to OpenShift console via browser
# Select "rhsso" identity provider
# Login as: bob@tenant-b.com

# Get token from console and login via CLI
oc login --token=<bob-token> --server=https://api.<cluster-domain>:6443

# Verify identity
oc whoami
# Expected: bob@tenant-b.com

# Verify accessible projects
oc get projects
# Expected: Shows tenant-b-* projects only
```

#### Step 3.2: Set Environment Variables

```bash
# Set cluster domain (tenant admins don't have permission to read cluster config)
# Derive from API server URL instead
export CLUSTER_DOMAIN=$(oc whoami --show-server | sed 's/.*api\.\(.*\):6443/apps.\1/')

# Set RH SSO URL (tenant admins don't have permission to read routes in sso namespace)
# Derive from cluster domain (assumes Keycloak route follows standard pattern)
export KEYCLOAK_URL="keycloak-sso.${CLUSTER_DOMAIN}"

# Verify
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo "Keycloak URL: ${KEYCLOAK_URL}"
```

#### Step 3.3: Deploy Model (LLMInferenceService)


# Deploy the model
```
cat tenant-b/00-tenant-b-model.yaml | envsubst | oc apply -f -
```

**What this creates:**
- LLMInferenceService in `tenant-b-models` namespace
- vLLM inference server
- Automatic creation of predictor service and HTTPRoute
- Model accessible via `tenant-b-gateway`

**Verification:**

```bash
# Check LLMInferenceService status
oc get llminferenceservice -n tenant-b-models

# Wait for LLMInferenceService to become Ready
# The Gateway-level AuthPolicy was already deployed by cluster admin in Step 1.8
oc wait --for=condition=Ready llminferenceservice/granite-3-1-8b-instruct-fp8 \
  -n tenant-b-models --timeout=5m

# Check automatically created resources
oc get httproute -n tenant-b-models
# Expected: <your-model-name>-kserve-route

oc get services -n tenant-b-models
# Expected: <your-model-name>-kserve-workload-svc

oc get deployment -n tenant-b-models
# Expected: <your-model-name>-kserve
```

**Note:** The LLMInferenceService should become `READY: True` shortly after deployment since the Gateway-level AuthPolicy was already applied by the cluster admin in Phase 1.

#### Step 3.4: End-to-End Testing for Tenant B

##### 3.4.1: Get Bob's JWT Token

```bash
# Set RH SSO OAuth credentials (if not already set)
export CLIENT_ID="<your-oauth-client-id>"
export CLIENT_SECRET="<your-oauth-client-secret>"
export KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath="{.spec.host}")  # test-maas"  # Your RH SSO tenant

# Get Bob's JWT token from RH SSO using Resource Owner Password Credentials (ROPC) flow
export BOB_TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=bob@tenant-b.com" \
  -d "password=<bob-password>" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

echo "Bob's token obtained: ${BOB_TOKEN:0:50}..."
```

##### 3.4.2: Decode and Verify Bob's Token Claims

```bash
# Decode the JWT payload to inspect claims
echo "$BOB_TOKEN" | cut -d'.' -f2 | python3 -c "import base64, json, sys; print(json.dumps(json.loads(base64.urlsafe_b64decode(sys.stdin.read() + '===')), indent=2))"
```

**Expected claims for bob@tenant-b.com (RH SSO/Keycloak):**
```json
{
  "exp": 1765478763,
  "iat": 1765478463,
  "jti": "aa43a57d-5b36-460d-a226-e97ca5349792",
  "iss": "https://keycloak-sso.apps.tenantai.kni.syseng.devcluster.openshift.com/auth/realms/maas-platform",
  "sub": "f5216fc2-7646-4a3f-a600-7cb6108597c6",
  "typ": "Bearer",
  "azp": "openshift",
  "session_state": "8dbc9fc1-f6d1-42ee-a187-cb008f3f7a9a",
  "scope": "openid profile email",
  "sid": "8dbc9fc1-f6d1-42ee-a187-cb008f3f7a9a",
  "accountId": "tenant-b",
  "email_verified": true,
  "name": "bob admin",
  "groups": [
    "tenant-b-admins"
  ],
  "preferred_username": "bob@tenant-b.com",
  "given_name": "bob",
  "family_name": "admin",
  "email": "bob@tenant-b.com"
}
```

**Key claims to verify:**
- `groups`: **ARRAY** `["tenant-b-admins"]` (must start with "tenant-b-")
- `preferred_username`: "bob" (or "bob@tenant-b.com" depending on configuration)
- `email`: "bob@tenant-b.com"
- `accountId`: "tenant-b" (custom user attribute)
- `sub`: UUID from Keycloak - Unique user ID

##### 3.4.3: Get Alice's JWT Token (for cross-tenant test)

```bash
# Get Alice's JWT token from RH SSO
export ALICE_TOKEN=$(curl -sk -X POST \
  "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=alice@tenant-a.com" \
  -d "password=<alice-password>" \
  -d "grant_type=password" \
  -d "scope=openid profile email" | jq -r '.access_token')

echo "Alice's token obtained: ${ALICE_TOKEN:0:50}..."
```

##### 3.4.4: Test Bob's Access to Tenant B Model (Should Succeed)

Set the model URL:
```bash
# Replace <your-model-name> with your actual model name from Step 3.3
export MODEL_URL="http://tenant-b.maas.${CLUSTER_DOMAIN}/tenant-b-models/granite-3-1-8b-instruct-fp8"
```

**Test 1: Chat completions with Bob's token (should succeed)**

```bash
echo "Test 1: Bob accessing Tenant B model..."
curl -k "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${BOB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.1-8b-instruct-fp8",
    "messages": [
      {"role": "user", "content": "Say hello in one sentence"}
    ],
    "max_tokens": 50
  }' | jq .
```

**Expected result:**
```json
{
  "id": "cmpl-abc123",
  "object": "chat.completion",
  "created": 1765213500,
  "model": "<your-model-name>",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I assist you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 10,
    "total_tokens": 22
  }
}
```

**Status**: HTTP 200 OK - Bob can access Tenant B model

##### 3.4.5: Test Alice's Access to Tenant B Model (Should Be Denied)

**Test 2: Chat completions with Alice's token (should fail)**

```bash
echo "Test 2: Alice accessing Tenant B model (cross-tenant access)..."
curl -v -k "${MODEL_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.1-8b-instruct-fp8",
    "messages": [
      {"role": "user", "content": "Say hello"}
    ],
    "max_tokens": 50
  }'
```

**Expected result:**
- HTTP Status Code: `403 Forbidden`
- Header: `x-ext-auth-reason: Unauthorized`

**Why Alice is denied access:**

The AuthPolicy for Tenant B Gateway contains a Rego rule that validates the tenant:

```rego
package tenant_validation

# Allow if groups claim starts with tenant-b-
allow {
  startswith(input.auth.identity.groups, "tenant-b-")
}
```

- Bob's `groups` claim: "tenant-b-admins"] → Starts with "tenant-b-" → **Allowed**
- Alice's `groups` claim: "tenant-a-admins"] → Does NOT start with "tenant-b-" → **Denied**

This ensures strict tenant isolation at the authorization layer.

##### Test Summary

**Bob (tenant-b-admins) - Test should succeed:**
| Test | Endpoint | Expected Result |
|------|----------|----------------|
| 1 | `/v1/chat/completions` | 200 OK (AI response) |

**Alice (tenant-a-admins) - Test should fail:**
| Test | Endpoint | Expected Result |
|------|----------|----------------|
| 2 | `/v1/chat/completions` | 403 Forbidden (Unauthorized) |

**Tenant B Deployment Complete!** 
