# Keycloak Manifests for Multi-Tenant MaaS Platform

This directory contains all Kubernetes manifests for deploying and configuring Red Hat SSO (Keycloak) for the multi-tenant MaaS platform.

## Directory Structure

```
keycloak/
├── 01-namespace.yaml              # SSO namespace
├── 02-operator-group.yaml         # OperatorGroup for RH SSO Operator
├── 03-operator-subscription.yaml  # RH SSO Operator subscription
├── 04-keycloak-instance.yaml      # Keycloak instance
├── 05-keycloak-realm.yaml         # maas-platform realm
├── 06-keycloak-client.yaml        # OpenShift OAuth client with protocol mappers
└── users/                          # User definitions
    ├── alice.yaml                  # Tenant A admin
    ├── tenant-a-dev1.yaml          # Tenant A developer
    ├── tenant-a-ml-eng1.yaml       # Tenant A ML engineer
    └── bob.yaml                    # Tenant B admin
```

## Deployment Order

Apply manifests in numerical order:

```bash
# 1. Deploy RH SSO Operator
oc apply -f 01-namespace.yaml
oc apply -f 02-operator-group.yaml
oc apply -f 03-operator-subscription.yaml

# Wait for operator to be ready
oc get csv -n sso -w

# 2. Deploy Keycloak instance
oc apply -f 04-keycloak-instance.yaml

# Wait for Keycloak to be ready
oc get keycloak maas-keycloak -n sso -w

# 3. Create realm
oc apply -f 05-keycloak-realm.yaml

# 4. Create OpenShift OAuth client (with protocol mappers)
# First, set cluster domain
export CLUSTER_DOMAIN=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' | sed 's/console-openshift-console\.//')

# Apply with environment variable substitution
envsubst < 06-keycloak-client.yaml | oc apply -f -

# 5. Create users
oc apply -f users/

# 6. Create groups and assign users via Keycloak Admin Console
# Note: Groups must be created manually via the Keycloak Admin Console
# See "Group Management" section below for detailed instructions
```

## Group Management

**Important**: The Keycloak Operator does not support creating groups via CRs. Groups must be created manually via the Keycloak Admin Console.

### Creating Groups via Admin Console

1. Get Keycloak admin credentials:
```bash
echo "Username: $(oc get secret credential-maas-keycloak -n sso -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -D)"
echo "Password: $(oc get secret credential-maas-keycloak -n sso -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -D)"
echo "URL: https://$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')/auth/admin/"
```

2. Login to Keycloak Admin Console
3. Navigate to: **maas-platform** realm → **Groups**
4. Create the following groups:
   - `tenant-a-admins`
   - `tenant-a-developers`
   - `tenant-a-ml-engineers`
   - `tenant-b-admins`

### Adding Users to Groups

After creating groups, add users to them:

1. Navigate to: **maas-platform** realm → **Users**
2. Find and click on the user (e.g., "alice")
3. Go to the **Groups** tab
4. Click **Join Group** and select the appropriate group:
   - alice → tenant-a-admins
   - tenant-a-dev1 → tenant-a-developers
   - tenant-a-ml-eng1 → tenant-a-ml-engineers
   - bob → tenant-b-admins
5. Click **Join**

### Verify Group Membership

After adding users to groups, verify the JWT token includes the groups claim:

```bash
# Set environment variables
export KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-openshift-client -n sso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -D)

# Get and decode token for alice
curl -k -s -X POST "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=openshift' \
  -d "client_secret=${CLIENT_SECRET}" \
  -d 'username=alice' \
  -d 'password=password123' \
  -d 'scope=openid profile email' | jq -r '.access_token' | cut -d'.' -f2 | base64 -D 2>/dev/null | jq '.groups'
```

This should now return: `["tenant-a-admins"]` instead of `[]`.

## Verification

```bash
# Check all resources
oc get keycloak,keycloakrealm,keycloakclient,keycloakuser -n sso

# Get admin credentials
echo "Username: $(oc get secret credential-maas-keycloak -n sso -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -D)"
echo "Password: $(oc get secret credential-maas-keycloak -n sso -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -D)"

# Get Keycloak URL
echo "URL: https://$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')/auth/admin/"

# Get OAuth client secret
oc get secret keycloak-client-secret-openshift-client -n sso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -D
```

### Verify JWT Token Claims

To verify that the JWT token includes the correct claims (groups, accountId, email, etc.):

```bash
# Set environment variables
export KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')
export CLIENT_SECRET=$(oc get secret keycloak-client-secret-openshift-client -n sso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -D)

# Get JWT token for alice
TOKEN=$(curl -k -s -X POST "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=openshift' \
  -d "client_secret=${CLIENT_SECRET}" \
  -d 'username=alice' \
  -d 'password=password123' \
  -d 'scope=openid profile email' | jq -r '.access_token')

# Display the token
echo "JWT Token:"
echo $TOKEN
echo ""

# Decode the token to verify claims
echo "Decoded JWT Claims:"
echo $TOKEN | cut -d'.' -f2 | base64 -D 2>/dev/null | jq '.'
```

**Expected JWT Claims:**
```json
{
  "sub": "f1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "preferred_username": "alice",
  "email": "alice@tenant-a.com",
  "groups": ["tenant-a-admins"],
  "accountId": "tenant-a",
  "iss": "https://<keycloak-url>/auth/realms/maas-platform",
  "aud": "openshift",
  "exp": 1234567890,
  "iat": 1234567890
}
```

**Key Claims to Verify:**
- `preferred_username`: Should be `alice` (or `alice@tenant-a.com` depending on configuration)
- `email`: Should be `alice@tenant-a.com`
- `groups`: Should be an **array** containing `["tenant-a-admins"]`
- `accountId`: Should be `tenant-a` (custom user attribute)
- `iss`: Should be `https://<keycloak-url>/auth/realms/maas-platform`

**Verify for other users:**
```bash
# Tenant A Developer
curl -k -s -X POST "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=openshift' \
  -d "client_secret=${CLIENT_SECRET}" \
  -d 'username=tenant-a-dev1' \
  -d 'password=password123' \
  -d 'scope=openid profile email' | jq -r '.access_token' | cut -d'.' -f2 | base64 -D 2>/dev/null | jq '.'

# Tenant B Admin
curl -k -s -X POST "https://${KEYCLOAK_URL}/auth/realms/maas-platform/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=openshift' \
  -d "client_secret=${CLIENT_SECRET}" \
  -d 'username=bob' \
  -d 'password=password123' \
  -d 'scope=openid profile email' | jq -r '.access_token' | cut -d'.' -f2 | base64 -D 2>/dev/null | jq '.'
```

## Customization

### Adding New Users

Create a new YAML file in the `users/` directory:

```yaml
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: new-user
  namespace: sso
  labels:
    app: sso
    tenant: tenant-a
    role: developer
spec:
  user:
    username: newuser
    email: newuser@tenant-a.com
    emailVerified: true
    enabled: true
    firstName: New
    lastName: User
    credentials:
      - type: password
        value: "password123"
        temporary: false
    groups:
      - tenant-a-developers
    attributes:
      accountId:
        - tenant-a
  realmSelector:
    matchLabels:
      app: sso
```

Apply with: `oc apply -f users/new-user.yaml`

### Changing Passwords

Edit the user YAML file and update the `value` field under `credentials`, then reapply.

## Cleanup

```bash
# Delete all users
oc delete -f users/

# Delete client
oc delete -f 06-keycloak-client.yaml

# Delete realm
oc delete -f 05-keycloak-realm.yaml

# Delete Keycloak instance
oc delete -f 04-keycloak-instance.yaml

# Delete operator
oc delete -f 03-operator-subscription.yaml
oc delete -f 02-operator-group.yaml

# Delete namespace
oc delete -f 01-namespace.yaml
```
