# Multi-Tenant MaaS Platform - Red Hat SSO Implementation

## Overview

This directory contains the **Red Hat Single Sign-On (Keycloak)** implementation of the multi-tenant Model-as-a-Service platform. The core architecture and design are documented in the [original tenancy repository](https://github.com/mpaulgreen/tenancy) - this implementation migrates the identity provider from IBM Verify to Red Hat SSO.

## What's Different from IBM Verify Implementation

**Identity Provider**: Red Hat SSO (Keycloak) instead of IBM Verify

**Key Changes:**
- JWT `groups` claim format: **Array** (`["tenant-a-admins"]`) instead of string
- OIDC issuer URL: `https://<keycloak-route>/auth/realms/maas-platform`
- On-premise Keycloak deployment vs. cloud-based IBM Verify
- Native OpenShift OAuth integration

**Architecture**: Identical to IBM Verify implementation (per-tenant Gateway, RBAC, monitoring, billing)

## Documentation Structure

### Implementation Guides (RH SSO-specific)

- **[RBAC Implementation with RH SSO](./tenant_admin_rbac_implementation_rhsso.md)**
  Step-by-step guide for tenant RBAC with Red Hat SSO integration

- **[MaaS Platform Deployment](./maas-platform/README.md)**
  Per-tenant Gateway deployment with RH SSO JWT authentication

- **[Monitoring Setup](./monitoring/README.md)**
  Tenant Prometheus, Grafana, and TimescaleDB (identity-provider agnostic)

### Design Documents (Reference)

For architecture and design details, see the original documentation:
- [RBAC Design](https://github.com/mpaulgreen/tenancy/blob/main/tenancy_rbac_design.md)
- [MaaS Platform Design](https://github.com/mpaulgreen/tenancy/blob/main/tenancy-design_model_as_a_service.md)
- [Monitoring & Billing Design](https://github.com/mpaulgreen/tenancy/blob/main/tenancy-design_monitoring_billing.md)

## Quick Start

### Prerequisites

- OpenShift 4.19+ cluster
- Red Hat OpenShift AI 3.0+
- Red Hat SSO operator deployed
- Kuadrant operator installed

### Deployment Steps

1. **Configure Red Hat SSO** (Cluster Admin)
   ```bash
   # Create maas-platform realm in Keycloak
   # Configure users with accountId attribute
   # Create tenant groups (tenant-a-admins, tenant-b-admins)
   # Set up OpenShift OAuth client with protocol mappers
   ```

2. **Deploy RBAC Foundation** (Cluster Admin)
   ```bash
   # Follow: tenant_admin_rbac_implementation_rhsso.md
   ```

3. **Deploy MaaS Platform** (Cluster Admin)
   ```bash
   cd maas-platform
   # Follow: maas-platform/README.md
   ```

4. **Enable Monitoring & Billing** (Cluster Admin)
   ```bash
   cd monitoring
   # Follow: monitoring/README.md
   ```

5. **Deploy Models** (Tenant Admin)
   ```bash
   # Login as tenant admin (alice@tenant-a.com)
   oc apply -f maas-platform/tenant-a/00-tenant-a-model.yaml
   ```

## Validated Configuration

**Deployment Scale:**
- 2 tenants (tenant-a, tenant-b)
- 1 model per tenant (granite-3-1-8b-instruct-fp8 with vLLM)
- Per-tenant Gateway, Prometheus, and Grafana

**Test Users:**
- `alice@tenant-a.com` (tenant-a-admins) - Enterprise tier
- `tenant-a-dev1@tenant-a.com` (tenant-a-developers) - Free tier
- `tenant-a-ml-eng1@tenant-a.com` (tenant-a-ml-engineers) - Premium tier
- `bob@tenant-b.com` (tenant-b-admins) - Enterprise tier

## Key Differences: RH SSO vs IBM Verify

| Aspect | IBM Verify | Red Hat SSO |
|--------|-----------|-------------|
| Deployment | Cloud SaaS | On-premise Kubernetes |
| Groups Claim Format | String: `"tenant-a-admins"` | Array: `["tenant-a-admins"]` |
| OIDC Issuer | `https://<tenant>.verify.ibm.com/oidc/endpoint/default` | `https://<keycloak-route>/auth/realms/maas-platform` |
| Custom Attributes | User attributes | User attributes |
| OpenShift Integration | OAuth via OIDC | Native OAuth integration |
| Token Expiry | ~2 hours | Configurable (default: 2 hours) |

## Components Status

 **RBAC with RH SSO** - Validated
 **Per-tenant Gateway** - Validated
 **AuthPolicy with JWT** - Validated
 **Request Rate Limiting** - Validated
 **Token Rate Limiting** - Validated
 **Tenant Prometheus Federation** - Validated
 **Grafana Dashboards** - Validated
 **TimescaleDB Billing** - Validated
 **Billing API with NULL handling** - Validated

## Files Updated for RH SSO Migration

### RBAC
- `tenant_admin_rbac_implementation_rhsso.md` - RH SSO setup and group mapping

### MaaS Platform
- `maas-platform/cluster-admin/06-tenant-a-policies.yaml` - Updated issuer URL
- `maas-platform/cluster-admin/07-tenant-b-policies.yaml` - Updated issuer URL
- AuthPolicy Rego rules - Handle array-based groups claim

### Monitoring
- No changes required (identity-provider agnostic YAML manifests)

### Billing
- `billing-app/pkg/db/db.go` - Added COALESCE() for NULL handling
- `billing-app/deployments/02-aggregator-cronjob.yaml` - Updated credentials
- `billing-app/deployments/03-api-deployment.yaml` - Updated credentials, imagePullPolicy

## References

- **Original Implementation**: [IBM Verify-based Tenancy Repository](https://github.com/mpaulgreen/tenancy)
- **RH SSO Documentation**: [Red Hat Single Sign-On](https://access.redhat.com/products/red-hat-single-sign-on)
- **OpenShift AI**: [Red Hat OpenShift AI Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- **Kuadrant**: [Kuadrant Documentation](https://docs.kuadrant.io/)
