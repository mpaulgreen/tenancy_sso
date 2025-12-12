# Tenant Administrator RBAC in Multi-Tenant OpenShift with Red Hat SSO

## Overview

This guide explains how to provide two (or more) tenant administrators with isolated administrative privileges in a single OpenShift cluster using **Red Hat Single Sign-On (RH SSO)** based on Keycloak. Each tenant admin has full control over their tenant's namespaces but cannot access or modify other tenants' resources.

## Table of Contents

1. [Red Hat SSO Setup for Tenant Admin Users](#1-red-hat-sso-setup-for-tenant-admin-users)
   - 1.1 Deploy Red Hat SSO Operator
   - 1.2 Create Keycloak Instance
   - 1.3 Create Realm for MaaS Platform
   - 1.4 Create Client for OpenShift (with Protocol Mappers)
   - 1.5 Create Users and Groups (via CRs)
   - 1.6 Verify Groups and Client Mappers

2. [Configure OpenShift OAuth with Red Hat SSO](#2-configure-openshift-oauth-with-red-hat-sso)
   - 2.1 Backup Current OAuth Configuration
   - 2.2 Get RH SSO Client Credentials
   - 2.3 Configure RH SSO Identity Provider in OpenShift
   - 2.4 Verify Configuration

3. [As a Cluster Admin](#3-as-a-cluster-admin)
   - 3.1 Create Tenant Namespaces
   - 3.2 Create Tenant Admin ClusterRole
   - 3.3 Create OpenShift Group Objects
   - 3.4 Create RoleBindings for Tenant Admins
   - 3.5 Validation of All the Above
   - 3.6 Creation of Resource Quota
   - 3.7 Implementing Pod Security Standards
   - 3.8 Example Scenario: Cluster Admin Adds New Namespace

4. [As a Tenant Admin](#4-as-a-tenant-admin)
   - 4.1 Create RoleBindings for Developers and ML Engineers
   - 4.2 Security Note - Namespace Isolation
   - 4.3 Keeping Groups in Sync
   - 4.4 Verify RBAC Permissions as Cluster Admin
   - 4.5 Verify RBAC Permissions as Tenant Admin
   - 4.6 List All Resources a Tenant Admin Can Manage

5. [Tenant Admin Capabilities](#5-tenant-admin-capabilities)
   - 5.1 What Tenant Admins CAN Do
   - 5.2 What Tenant Admins CANNOT Do

6. [Example Scenarios](#6-example-scenarios)
   - 6.1 Scenario 1: Tenant A Admin Deploys a Model
   - 6.2 Scenario 2: Tenant A Admin Creates Developer Access

7. [Summary](#7-summary)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenShift Cluster                             │
│                                                                   │
│  ┌─────────────────────────┐  ┌─────────────────────────┐       │
│  │   Tenant A Admin        │  │   Tenant B Admin        │       │
│  │   (alice@tenant-a.com)  │  │   (bob@tenant-b.com)    │       │
│  └───────────┬─────────────┘  └───────────┬─────────────┘       │
│              │                             │                     │
│              │ RoleBindings                │ RoleBindings        │
│              ▼                             ▼                     │
│  ┌─────────────────────────┐  ┌─────────────────────────┐       │
│  │  Tenant A Namespaces    │  │  Tenant B Namespaces    │       │
│  ├─────────────────────────┤  ├─────────────────────────┤       │
│  │ tenant-a-models         │  │ tenant-b-models         │       │
│  │ tenant-a-data           │  │ tenant-b-data           │       │
│  │ tenant-a-monitoring     │  │ tenant-b-monitoring     │       │
│  └─────────────────────────┘  └─────────────────────────┘       │
│                                                                   │
│  Cluster Admin (system:admin)                                    │
│  - Can manage all tenants                                        │
│  - Creates tenant namespaces                                     │
│  - Assigns tenant admins                                         │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ OIDC Authentication
                              │
┌─────────────────────────────────────────────────────────────────┐
│              Red Hat Single Sign-On (Keycloak)                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Realm: maas-platform                                       │  │
│  │                                                             │  │
│  │ Client: openshift                                           │  │
│  │ - Client ID: openshift                                      │  │
│  │ - Protocol: openid-connect                                  │  │
│  │ - Access Type: confidential                                 │  │
│  │                                                             │  │
│  │ Groups:                  Users:                             │  │
│  │ - tenant-a-admins       - alice@tenant-a.com               │  │
│  │ - tenant-a-developers   - tenant-a-dev1@tenant-a.com       │  │
│  │ - tenant-a-ml-engineers - tenant-a-ml-eng1@tenant-a.com    │  │
│  │ - tenant-b-admins       - bob@tenant-b.com                 │  │
│  │                                                             │  │
│  │ User Attributes:                                            │  │
│  │ - accountId (tenant identifier)                             │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## 1. Red Hat SSO Setup for Tenant Admin Users

All Keycloak manifests and deployment instructions are available in the `keycloak/` directory.

**📖 For complete deployment instructions, see: [`keycloak/README.md`](keycloak/README.md)**

### Quick Reference

The deployment creates:

**Keycloak Resources:**
- RH SSO Operator (installed from OperatorHub)
- Keycloak instance with PostgreSQL backend
- `maas-platform` realm
- OpenShift OAuth client with protocol mappers (groups, accountId, email, preferred_username)

**Users & Groups:**
- `alice@tenant-a.com` (Tenant A Admin)
- `tenant-a-dev1@tenant-a.com` (Tenant A Developer)
- `tenant-a-ml-eng1@tenant-a.com` (Tenant A ML Engineer)
- `bob@tenant-b.com` (Tenant B Admin)

All users have password: `password123`

**Note on Groups**: Groups must be created and users assigned to them manually via the Keycloak Admin Console. See [`keycloak/README.md#group-management`](keycloak/README.md#group-management) for detailed instructions.

**Expected JWT Token Claims:**
```json
{
  "sub": "f1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "preferred_username": "alice@tenant-a.com",
  "email": "alice@tenant-a.com",
  "groups": ["tenant-a-admins"],
  "accountId": "tenant-a",
  "iss": "https://<keycloak-url>/auth/realms/maas-platform"
}
```

**To retrieve and verify JWT tokens**, see the detailed instructions in [`keycloak/README.md`](keycloak/README.md#verify-jwt-token-claims) which includes:
- Commands to get JWT token for alice and other users
- How to decode tokens using command line
- Using jwt.io for verification
- Expected claims for each user type

**Note**: RH SSO/Keycloak returns:
- `groups` as an **array**, not a string (unlike IBM Verify)
- `accountId` as a **custom user attribute**
- `sub` as a UUID, not the username (use `preferred_username` for email)

---

## 2. Configure OpenShift OAuth with Red Hat SSO

**Note**: This step configures OpenShift cluster authentication to use RH SSO for console and CLI login.

**Important**: The OAuth resource in OpenShift is a **cluster-wide singleton** that must be named `cluster`. Modifying OAuth can affect cluster login - always backup before making changes.

### 2.1 Backup Current OAuth Configuration

**Always backup the OAuth configuration before making changes:**

```bash
# Create backup directory
mkdir -p ~/openshift-oauth-backup
cd ~/openshift-oauth-backup

# Backup OAuth configuration with timestamp
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
oc get oauth cluster -o yaml > oauth-cluster-backup-${BACKUP_DATE}.yaml

echo "OAuth configuration backed up to: oauth-cluster-backup-${BACKUP_DATE}.yaml"

# Verify backup file
ls -lh oauth-cluster-backup-${BACKUP_DATE}.yaml
cat oauth-cluster-backup-${BACKUP_DATE}.yaml
```

**To restore from backup if needed:**

```bash
# List available backups
ls -lh ~/openshift-oauth-backup/

# Restore from backup (replace with your backup filename)
oc apply -f ~/openshift-oauth-backup/oauth-cluster-backup-YYYYMMDD_HHMMSS.yaml

# Wait for OAuth pods to restart
oc get pods -n openshift-authentication -w
```

### 2.2 Get RH SSO Client Credentials

```bash
# Get Keycloak URL
KEYCLOAK_URL=$(oc get route keycloak -n sso -o jsonpath='{.spec.host}')
echo "Keycloak URL: https://$KEYCLOAK_URL"

# Get OpenShift client secret
OPENSHIFT_CLIENT_SECRET=$(oc get secret keycloak-client-secret-openshift-client -n sso -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
echo "Client Secret: $OPENSHIFT_CLIENT_SECRET"

# Set environment variables
export KEYCLOAK_URL
export OPENSHIFT_CLIENT_SECRET
```

### 2.3 Configure RH SSO Identity Provider in OpenShift

**Check current OAuth configuration:**

```bash
echo "Current identity providers:"
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' && echo
```

**Create the client secret:**

```bash
oc create secret generic rhsso-client-secret \
  --from-literal=clientSecret=${OPENSHIFT_CLIENT_SECRET} \
  -n openshift-config
```

**Add RH SSO identity provider:**

```bash
# Configure RH SSO OIDC identity provider
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: rhsso
    mappingMethod: claim
    type: OpenID
    openID:
      clientID: openshift
      clientSecret:
        name: rhsso-client-secret
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      issuer: https://${KEYCLOAK_URL}/auth/realms/maas-platform
      ca:
        name: ""
EOF
```

**Understanding `mappingMethod: claim`:**
- Creates User and Identity objects for authentication
- **Does NOT** automatically create or sync Group objects from JWT claims
- Group objects must be created and managed manually (see Section 3.3)
- Provides better control over group membership in multi-tenant scenarios

**Alternative: Use CA bundle if using self-signed certificates:**

```bash
# Get Keycloak CA certificate
oc get secret keycloak-tls-secret -n sso -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/keycloak-ca.crt

# Create ConfigMap with CA
oc create configmap rhsso-ca-cert \
  --from-file=ca.crt=/tmp/keycloak-ca.crt \
  -n openshift-config

# Update OAuth config to reference CA
cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: rhsso
    mappingMethod: claim
    type: OpenID
    openID:
      clientID: openshift
      clientSecret:
        name: rhsso-client-secret
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      issuer: https://${KEYCLOAK_URL}/auth/realms/maas-platform
      ca:
        name: rhsso-ca-cert
EOF
```

### 2.4 Verify Configuration

```bash
# Check updated OAuth configuration
oc get oauth cluster -o yaml

# Verify RH SSO identity provider is present
oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.name=="rhsso")]}' | jq '.'

# Wait for OAuth pods to restart (this takes 2-5 minutes)
oc get pods -n openshift-authentication -w
```

**Test login:**

1. Logout from OpenShift Console
2. Access OpenShift Console: `https://console-openshift-console.${CLUSTER_DOMAIN}`
3. You should see "rhsso" as a login option
4. Click "rhsso" and login with alice@tenant-a.com

**Test CLI login:**

```bash
# Get login URL
oc whoami --show-server

# In browser, go to: https://oauth-openshift.${CLUSTER_DOMAIN}/oauth/token/request
# Login with RH SSO
# Copy the displayed token

# Login with token
oc login --token=<token-from-browser>

# Verify user
oc whoami
# Should show: alice@tenant-a.com
```

## 3. As a Cluster Admin

The following steps must be performed by a cluster administrator to set up the multi-tenant environment.

### 3.1 Create Tenant Namespaces

```bash
# Tenant A namespaces
oc create namespace tenant-a-models
oc create namespace tenant-a-data
oc create namespace tenant-a-monitoring

# Tenant B namespaces
oc create namespace tenant-b-models
oc create namespace tenant-b-data
oc create namespace tenant-b-monitoring

# Label namespaces for easy identification
oc label namespace tenant-a-models tenant=tenant-a
oc label namespace tenant-a-data tenant=tenant-a
oc label namespace tenant-a-monitoring tenant=tenant-a

oc label namespace tenant-b-models tenant=tenant-b
oc label namespace tenant-b-data tenant=tenant-b
oc label namespace tenant-b-monitoring tenant=tenant-b
```

### 3.2 Create Tenant Admin ClusterRole

Create a ClusterRole that defines tenant admin permissions:

```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tenant-admin
rules:
# Full access to most resources in assigned namespaces
- apiGroups: ["", "apps", "batch", "extensions"]
  resources: ["*"]
  verbs: ["*"]

# Allow creating Roles and RoleBindings
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["*"]

# Allow binding view and edit ClusterRoles
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  resourceNames: ["view", "edit", "admin"]
  verbs: ["bind"]

# Allow managing Routes
- apiGroups: ["route.openshift.io"]
  resources: ["routes", "routes/custom-host"]
  verbs: ["*"]

# Allow managing image streams
- apiGroups: ["image.openshift.io"]
  resources: ["imagestreams", "imagestreamtags", "imagestreamimages"]
  verbs: ["*"]

# Allow managing builds
- apiGroups: ["build.openshift.io"]
  resources: ["builds", "buildconfigs"]
  verbs: ["*"]

# KServe / ServingRuntime resources
- apiGroups: ["serving.kserve.io"]
  resources: ["*"]
  verbs: ["*"]

# Monitoring resources
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors", "podmonitors", "prometheusrules"]
  verbs: ["*"]

# Kuadrant resources
- apiGroups: ["kuadrant.io"]
  resources: ["authpolicies", "ratelimitpolicies"]
  verbs: ["*"]

# Gateway API resources
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes", "grpcroutes", "tcproutes", "tlsroutes", "udproutes"]
  verbs: ["*"]

# Secrets and ConfigMaps
- apiGroups: [""]
  resources: ["secrets", "configmaps"]
  verbs: ["*"]

# PVCs
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["*"]

# Services and ServiceAccounts
- apiGroups: [""]
  resources: ["services", "serviceaccounts"]
  verbs: ["*"]

# Network Policies
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["*"]

# Allow viewing nodes (read-only) for troubleshooting
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]

# Allow viewing namespaces (read-only)
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list"]
EOF
```

**Verify ClusterRole creation:**

```bash
oc get clusterrole tenant-admin
oc describe clusterrole tenant-admin
```

### 3.3 Create OpenShift Group Objects

**Important**: OpenShift Group objects must be created manually. The `mappingMethod: claim` does NOT auto-create groups from JWT claims for all ouath providers like IBM verify.

```bash
# Create Tenant A groups
oc adm groups new tenant-a-admins
oc adm groups new tenant-a-developers
oc adm groups new tenant-a-ml-engineers

# Create Tenant B groups
oc adm groups new tenant-b-admins

# Verify groups were created
oc get groups
```

**Add users to OpenShift groups:**

```bash
# Important: Users must login at least once before they can be added to groups
# Login as alice@tenant-a.com first via console or CLI

# Add users to Tenant A groups
oc adm groups add-users tenant-a-admins alice@tenant-a.com
oc adm groups add-users tenant-a-developers tenant-a-dev1@tenant-a.com
oc adm groups add-users tenant-a-ml-engineers tenant-a-ml-eng1@tenant-a.com

# Add users to Tenant B groups
oc adm groups add-users tenant-b-admins bob@tenant-b.com

# Verify group membership
oc get group tenant-a-admins -o yaml
oc get group tenant-b-admins -o yaml
```

### 3.4 Create RoleBindings for All Tenant User Groups

**IMPORTANT**: Create RoleBindings for ALL user groups (admins, developers, ml-engineers) during initial setup. This ensures all users can see their tenant projects immediately upon login.

**Permission Model:**
- **Admins** → `tenant-admin` ClusterRole (full namespace admin + RBAC management)
- **Developers** → `view` ClusterRole (read-only access)
- **ML Engineers** → `edit` ClusterRole (create/modify resources, no RBAC)

**Tenant A RoleBindings:**

```bash
# Tenant A - Admins (full namespace admin)
oc create rolebinding tenant-a-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-a-admins \
  -n tenant-a-models

oc create rolebinding tenant-a-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-a-admins \
  -n tenant-a-data

oc create rolebinding tenant-a-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-a-admins \
  -n tenant-a-monitoring

# Tenant A - Developers (read-only)
oc create rolebinding tenant-a-developers-view \
  --clusterrole=view \
  --group=tenant-a-developers \
  -n tenant-a-models

oc create rolebinding tenant-a-developers-view \
  --clusterrole=view \
  --group=tenant-a-developers \
  -n tenant-a-data

oc create rolebinding tenant-a-developers-view \
  --clusterrole=view \
  --group=tenant-a-developers \
  -n tenant-a-monitoring

# Tenant A - ML Engineers (edit access)
oc create rolebinding tenant-a-ml-engineers-edit \
  --clusterrole=edit \
  --group=tenant-a-ml-engineers \
  -n tenant-a-models

oc create rolebinding tenant-a-ml-engineers-edit \
  --clusterrole=edit \
  --group=tenant-a-ml-engineers \
  -n tenant-a-data

oc create rolebinding tenant-a-ml-engineers-edit \
  --clusterrole=edit \
  --group=tenant-a-ml-engineers \
  -n tenant-a-monitoring
```

**Tenant B RoleBindings:**

```bash
# Tenant B - Admins (full namespace admin)
oc create rolebinding tenant-b-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-b-admins \
  -n tenant-b-models

oc create rolebinding tenant-b-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-b-admins \
  -n tenant-b-data

oc create rolebinding tenant-b-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-b-admins \
  -n tenant-b-monitoring
```

**Verify RoleBindings:**

```bash
# Check Tenant A role bindings for all groups
oc get rolebinding -n tenant-a-models
oc get rolebinding -n tenant-a-data
oc get rolebinding -n tenant-a-monitoring

# Verify specific bindings
oc describe rolebinding tenant-a-admins-binding -n tenant-a-models
oc describe rolebinding tenant-a-developers-view -n tenant-a-models
oc describe rolebinding tenant-a-ml-engineers-edit -n tenant-a-models

# Check Tenant B role bindings
oc get rolebinding -n tenant-b-models
oc get rolebinding -n tenant-b-data
oc get rolebinding -n tenant-b-monitoring
```

### 3.5 Validation of All the Above

**Important**: When testing with impersonation, you must specify both `--as` (user) and `--as-group` (group) to properly test RBAC permissions.

**Test Tenant A admin access:**

```bash
# Impersonate Tenant A admin (with group)
oc auth can-i create pods -n tenant-a-models --as=alice@tenant-a.com --as-group=tenant-a-admins
# Should return: yes

oc auth can-i create rolebindings -n tenant-a-models --as=alice@tenant-a.com --as-group=tenant-a-admins
# Should return: yes

# Verify Tenant A admin CANNOT access Tenant B resources
oc auth can-i create pods -n tenant-b-models --as=alice@tenant-a.com --as-group=tenant-a-admins
# Should return: no
```

**Test Tenant B admin access:**

```bash
# Impersonate Tenant B admin (with group)
oc auth can-i create pods -n tenant-b-models --as=bob@tenant-b.com --as-group=tenant-b-admins
# Should return: yes

# Verify Tenant B admin CANNOT access Tenant A resources
oc auth can-i create pods -n tenant-a-models --as=bob@tenant-b.com --as-group=tenant-b-admins
# Should return: no
```

**Test Tenant A developers (read-only):**

```bash
# Developers can view resources
oc auth can-i get pods -n tenant-a-models --as=tenant-a-dev1@tenant-a.com --as-group=tenant-a-developers
# Should return: yes

oc auth can-i get deployments -n tenant-a-models --as=tenant-a-dev1@tenant-a.com --as-group=tenant-a-developers
# Should return: yes

# Developers CANNOT create/modify resources
oc auth can-i create pods -n tenant-a-models --as=tenant-a-dev1@tenant-a.com --as-group=tenant-a-developers
# Should return: no

oc auth can-i delete pods -n tenant-a-models --as=tenant-a-dev1@tenant-a.com --as-group=tenant-a-developers
# Should return: no

# Developers CANNOT access other tenant namespaces
oc auth can-i get pods -n tenant-b-models --as=tenant-a-dev1@tenant-a.com --as-group=tenant-a-developers
# Should return: no
```

**Test Tenant A ML engineers (edit access):**

```bash
# ML Engineers can view resources
oc auth can-i get pods -n tenant-a-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: yes

# ML Engineers CAN create/modify resources
oc auth can-i create pods -n tenant-a-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: yes

oc auth can-i delete pods -n tenant-a-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: yes

oc auth can-i create deployments -n tenant-a-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: yes

# ML Engineers CANNOT create RoleBindings (no RBAC management)
oc auth can-i create rolebindings -n tenant-a-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: no

# ML Engineers CANNOT access other tenant namespaces
oc auth can-i get pods -n tenant-b-models --as=tenant-a-ml-eng1@tenant-a.com --as-group=tenant-a-ml-engineers
# Should return: no
```

### 3.6 Creation of Resource Quota

**Apply resource quotas to tenant namespaces:**

```bash
# Tenant A models namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-models-quota
  namespace: tenant-a-models
spec:
  hard:
    requests.cpu: "32"
    requests.memory: "128Gi"
    requests.nvidia.com/gpu: "4"
    limits.cpu: "64"
    limits.memory: "256Gi"
    limits.nvidia.com/gpu: "4"
    persistentvolumeclaims: "10"
    requests.storage: "500Gi"
EOF

# Tenant A data namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-data-quota
  namespace: tenant-a-data
spec:
  hard:
    persistentvolumeclaims: "20"
    requests.storage: "1Ti"
EOF

# Tenant A monitoring namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-monitoring-quota
  namespace: tenant-a-monitoring
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "16Gi"
    limits.cpu: "8"
    limits.memory: "32Gi"
    persistentvolumeclaims: "5"
    requests.storage: "200Gi"
EOF

# Tenant B models namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-b-models-quota
  namespace: tenant-b-models
spec:
  hard:
    requests.cpu: "32"
    requests.memory: "128Gi"
    requests.nvidia.com/gpu: "4"
    limits.cpu: "64"
    limits.memory: "256Gi"
    limits.nvidia.com/gpu: "4"
    persistentvolumeclaims: "10"
    requests.storage: "500Gi"
EOF

# Tenant B data namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-b-data-quota
  namespace: tenant-b-data
spec:
  hard:
    persistentvolumeclaims: "20"
    requests.storage: "1Ti"
EOF

# Tenant B monitoring namespace quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-b-monitoring-quota
  namespace: tenant-b-monitoring
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "16Gi"
    limits.cpu: "8"
    limits.memory: "32Gi"
    persistentvolumeclaims: "5"
    requests.storage: "200Gi"
EOF
```

**Verify quotas:**

```bash
# Tenant A quotas
oc get resourcequota -n tenant-a-models
oc describe resourcequota tenant-a-models-quota -n tenant-a-models

# Tenant B quotas
oc get resourcequota -n tenant-b-models
oc describe resourcequota tenant-b-models-quota -n tenant-b-models
```

### 3.7 Implementing Pod Security Standards

**Apply Pod Security labels to tenant namespaces:**

```bash
# Tenant A namespaces - baseline security
oc label namespace tenant-a-models \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

oc label namespace tenant-a-data \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

oc label namespace tenant-a-monitoring \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# Tenant B namespaces - baseline security
oc label namespace tenant-b-models \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

oc label namespace tenant-b-data \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

oc label namespace tenant-b-monitoring \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

**Verify Pod Security labels:**

```bash
oc get namespace tenant-a-models -o yaml | grep pod-security
```

### 3.8 Example Scenario: Cluster Admin Adds New Namespace

When a tenant needs a new namespace:

```bash
# Create new namespace
oc create namespace tenant-a-apps

# Label it
oc label namespace tenant-a-apps tenant=tenant-a

# Create RoleBinding
oc create rolebinding tenant-a-admins-binding \
  --clusterrole=tenant-admin \
  --group=tenant-a-admins \
  -n tenant-a-apps

# Apply quota
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-apps-quota
  namespace: tenant-a-apps
spec:
  hard:
    requests.cpu: "16"
    requests.memory: "64Gi"
    persistentvolumeclaims: "10"
    requests.storage: "200Gi"
EOF

# Apply Pod Security
oc label namespace tenant-a-apps \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

## 4. As a Tenant Admin

Once a cluster admin has granted you tenant admin access, you can perform these operations.

### 4.1 Manage Additional RoleBindings (Optional)

**NOTE**: RoleBindings for developers and ML engineers are already created by the cluster admin during tenant setup (Section 3.4). This section shows how tenant admins can create ADDITIONAL RoleBindings if needed for new users or custom access levels.

**Existing RoleBindings (created by cluster admin):**
- ✅ `tenant-a-admins-binding` → `tenant-admin` ClusterRole → `tenant-a-admins` group
- ✅ `tenant-a-developers-view` → `view` ClusterRole → `tenant-a-developers` group
- ✅ `tenant-a-ml-engineers-edit` → `edit` ClusterRole → `tenant-a-ml-engineers` group

**Example: Grant access to individual users (if not using groups):**

```bash
# Grant view access to a specific developer
oc create rolebinding dev-specific-view \
  --clusterrole=view \
  --user=newdev@tenant-a.com \
  -n tenant-a-models

# Grant edit access to a specific ML engineer
oc create rolebinding ml-specific-edit \
  --clusterrole=edit \
  --user=newml@tenant-a.com \
  -n tenant-a-models
```

**Example: Create custom role for specific use case:**

```bash
# Create a custom role for read-only metrics access
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: metrics-reader
  namespace: tenant-a-models
rules:
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
EOF

# Bind it to a user
oc create rolebinding metrics-reader-binding \
  --role=metrics-reader \
  --user=analyst@tenant-a.com \
  -n tenant-a-models
```

**Verify existing RoleBindings:**

```bash
# List all RoleBindings in tenant namespaces
oc get rolebindings -n tenant-a-models
oc get rolebindings -n tenant-a-data
oc get rolebindings -n tenant-a-monitoring

# Describe specific RoleBinding
oc describe rolebinding tenant-a-developers-view -n tenant-a-models
```

### 4.2 Security Note - Namespace Isolation

**Important Security Consideration:**
- Tenant admins can create RoleBindings to grant access to their namespaces
- However, they can ONLY bind the following ClusterRoles: `view`, `edit`, `admin`
- They CANNOT bind `cluster-admin` or custom ClusterRoles
- They CANNOT access other tenants' namespaces
- They CANNOT create or modify cluster-wide resources

### 4.3 Keeping Groups in Sync

**Manual Sync Required:**

When new users are added to RH SSO groups, they must be manually added to OpenShift groups:

```bash
# Example: New developer joins Tenant A
# 1. Add user to RH SSO group (in Keycloak): tenant-a-developers
# 2. User logs into OpenShift at least once
# 3. Cluster admin adds user to OpenShift group:
oc adm groups add-users tenant-a-developers tenant-a-dev2@tenant-a.com
```

**Future Enhancement:**
Consider using Group Sync Operator for automated synchronization between RH SSO and OpenShift groups.

### 4.4 Verify RBAC Permissions as Cluster Admin

**Important**: Include `--as-group` when testing with impersonation.

```bash
# Check what Tenant A admin can do
oc auth can-i --list --as=alice@tenant-a.com --as-group=tenant-a-admins -n tenant-a-models

# Specific permission checks
oc auth can-i create deployments -n tenant-a-models --as=alice@tenant-a.com --as-group=tenant-a-admins
oc auth can-i create rolebindings -n tenant-a-models --as=alice@tenant-a.com --as-group=tenant-a-admins
oc auth can-i delete namespaces --as=alice@tenant-a.com --as-group=tenant-a-admins
oc auth can-i create clusterroles --as=alice@tenant-a.com --as-group=tenant-a-admins
```

### 4.5 Verify RBAC Permissions as Tenant Admin

```bash
# As alice@tenant-a.com, check your permissions
oc auth can-i --list -n tenant-a-models
oc auth can-i create pods -n tenant-a-models
oc auth can-i create rolebindings -n tenant-a-models

# Try accessing Tenant B namespace (should fail)
oc auth can-i create pods -n tenant-b-models
oc get pods -n tenant-b-models
```

### 4.6 List All Resources a Tenant Admin Can Manage

```bash
# As alice@tenant-a.com
oc api-resources --verbs=list --namespaced=true -o name | \
  while read resource; do
    echo "Checking $resource..."
    oc auth can-i create $resource -n tenant-a-models
  done
```

## 5. Tenant Admin Capabilities

### 5.1 What Tenant Admins CAN Do

**Within their tenant namespaces, tenant admins can:**

1. **Deploy applications and models:**
   - Create Deployments, StatefulSets, DaemonSets
   - Create Pods, ReplicaSets, Jobs, CronJobs
   - Deploy KServe InferenceServices
   - Create Services, Routes, Ingresses

2. **Manage storage:**
   - Create PersistentVolumeClaims
   - Create ConfigMaps and Secrets

3. **Manage RBAC (limited):**
   - Create Roles and RoleBindings
   - Bind `view`, `edit`, and `admin` ClusterRoles to users/groups
   - Grant access to developers and ML engineers

4. **Manage networking:**
   - Create Services, Routes
   - Create NetworkPolicies
   - Create HTTPRoutes (Gateway API)
   - Create AuthPolicies and RateLimitPolicies (Kuadrant)

5. **Manage monitoring:**
   - Create ServiceMonitors and PodMonitors
   - Deploy Prometheus, Grafana

6. **View cluster-level info (read-only):**
   - List nodes
   - List namespaces
   - View cluster version

### 5.2 What Tenant Admins CANNOT Do

**Tenant admins are restricted from:**

1. **Cluster-wide operations:**
   - Create or delete Namespaces
   - Create or modify ClusterRoles
   - Create or modify ClusterRoleBindings
   - Modify cluster OAuth configuration
   - Access openshift-* system namespaces

2. **Other tenants' resources:**
   - Cannot view or modify tenant-b-* namespaces
   - Cannot access other tenants' secrets or data

3. **Privileged operations:**
   - Cannot create privileged pods (Pod Security enforced)
   - Cannot bind custom ClusterRoles
   - Cannot escalate to cluster-admin

4. **Resource limits:**
   - Cannot exceed ResourceQuotas set by cluster admin
   - Cannot modify ResourceQuotas or LimitRanges

## 6. Example Scenarios

### 6.1 Scenario 1: Tenant A Admin Deploys a Model

**As alice@tenant-a.com:**

```bash
# Create a deployment in tenant-a-models namespace
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-model
  namespace: tenant-a-models
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-model
  template:
    metadata:
      labels:
        app: test-model
    spec:
      containers:
      - name: model
        image: registry.access.redhat.com/ubi8/ubi-minimal:latest
        command: ["sh", "-c", "echo 'Model server running' && sleep infinity"]
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
EOF

# Verify deployment
oc get deployments -n tenant-a-models
oc get pods -n tenant-a-models
```

### 6.2 Scenario 2: Tenant A Admin Creates Developer Access

**As alice@tenant-a.com:**

```bash
# Grant view access to a new developer
oc create rolebinding dev3-view \
  --clusterrole=view \
  --user=tenant-a-dev3@tenant-a.com \
  -n tenant-a-models

# Verify
oc get rolebindings -n tenant-a-models
oc describe rolebinding dev3-view -n tenant-a-models
```

