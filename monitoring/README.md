# Multi-Tenant Model Usage Monitoring & Billing - Implementation Guide

This guide provides step-by-step instructions for implementing the monitoring and billing architecture for the multi-tenant MaaS platform.

## Architecture Overview

This implementation follows the **Dedicated Tenant Prometheus with Federation** model where:

- **Cluster Admin** sets up the platform infrastructure (User Workload Monitoring, billing services, federation RBAC)
- **Tenant Admins** deploy their own Prometheus + Grafana stack in their monitoring namespace
- **Per-tenant isolation** via dedicated Prometheus instances that federate only their namespace's metrics
- **No authentication complexity** - Grafana queries local tenant Prometheus without tokens/OAuth

**Key Components:**
- OpenShift User Workload Monitoring (centralized Prometheus)
- Tenant-owned Prometheus instances (federation-based)
- Tenant-owned Grafana instances (simple auth)
- TimescaleDB for long-term billing data storage
- Billing API for usage tracking and cost calculation

**Why This Approach:**
- Clean tenant isolation - each tenant has their own Prometheus with only their metrics
- No OAuth/authentication complexity - Grafana and Prometheus in same namespace
- Federation filters by namespace automatically
- Independent scaling per tenant
- Extra resource overhead per tenant (acceptable trade-off)

---

## Prerequisites

### Cluster Requirements
- OpenShift 4.12+ cluster
- Cluster admin access
- Storage provisioner (gp3-csi recommended)
- GPU nodes with NVIDIA drivers (for model serving)

### Existing Setup
This monitoring implementation builds on top of the existing MaaS platform:
- Tenant namespaces created (`tenant-a-models`, `tenant-b-models`)
- Tenant monitoring namespaces created (`tenant-a-monitoring`, `tenant-b-monitoring`)
- RBAC configured (tenant admins can manage their monitoring namespace)
- Models deployed (LLMInferenceService with vLLM)

### Required CLI Tools
```bash
oc version  # OpenShift CLI 4.12+
kubectl version  # Kubernetes CLI
```

---

## Phase 1: Cluster Admin Setup

The cluster admin performs these steps **once** to set up the platform infrastructure.

### Step 1.1: Enable User Workload Monitoring

Enable Prometheus User Workload Monitoring to allow tenant metrics scraping:

```bash
cd cluster-admin/

# Apply the cluster monitoring configuration
oc apply -f 01-enable-user-workload-monitoring.yaml
```

**Wait for user workload monitoring pods to start:**

```bash
# Monitor pod creation (this may take 2-5 minutes)
oc get pods -n openshift-user-workload-monitoring -w

# Expected pods:
# - prometheus-user-workload-0 (and -1 for HA)
# - prometheus-operator
# - thanos-ruler-user-workload-0 (and -1)
```

**Verify Prometheus is ready:**

```bash
oc wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus \
  -n openshift-user-workload-monitoring --timeout=600s
```

### Step 1.2: Create Billing Namespace

Create the shared billing namespace:

```bash
oc apply -f 02-maas-billing-namespace.yaml

# Verify namespace created
oc get namespace maas-billing
```

### Step 1.3: Deploy TimescaleDB

Deploy TimescaleDB for long-term billing data storage:

```bash
oc apply -f 03-timescaledb-statefulset.yaml

# Wait for TimescaleDB to be ready (this may take 2-3 minutes)
oc wait --for=condition=ready pod -l app=timescaledb \
  -n maas-billing --timeout=300s

# Verify TimescaleDB is running
oc get pods -n maas-billing
oc get pvc -n maas-billing
```

**Initialize the database schema:**

```bash
# Extract init.sql from ConfigMap and pipe directly to psql
oc get configmap timescaledb-init -n maas-billing -o jsonpath='{.data.init\.sql}' | \
  oc exec -i -n maas-billing timescaledb-0 -- psql -U billing -d maas_billing
```

### Step 1.4: Deploy Billing API

**IMPORTANT:** This step deploys a **placeholder nginx container**, not a functional billing API.

```bash
oc apply -f 04-billing-api-deployment.yaml

# Wait for deployment
oc wait --for=condition=available deployment/billing-api \
  -n maas-billing --timeout=300s
```

### Step 1.5: Grant Tenant Access to Billing API

```bash
oc apply -f 05-tenant-billing-access.yaml
```

### Step 1.6: Configure Tenant Prometheus Federation RBAC

**NEW STEP** - Grant tenant Prometheus instances permission to federate metrics:

```bash
oc apply -f 07-tenant-prometheus-rbac.yaml

# Verify ClusterRoleBindings created
oc get clusterrolebinding | grep prometheus-cluster-monitoring-view
```

**Cluster Admin Setup Complete!**

---

## Phase 2: Tenant A Administrator Setup

Tenant administrators perform these steps in their respective monitoring namespaces.

**Login as Tenant A Admin:**

```bash
# Get your JWT token from Red Hat SSO (Keycloak) and login
oc login --token=<alice-jwt-token> --server=https://api.CLUSTER_DOMAIN:6443

# Verify you're logged in as tenant admin
oc whoami
# Expected: alice@tenant-a.com

# Verify access to tenant-a-monitoring namespace
oc project tenant-a-monitoring
```

### Step 2.1: Verify Automatic Metrics Collection

**IMPORTANT**: KServe automatically creates a PodMonitor for vLLM metrics collection.

**Check the automatically created PodMonitor:**

```bash
cd ../tenant-a/

# Verify PodMonitor exists (created automatically by KServe)
oc get podmonitor -n tenant-a-models

# Expected output:
# NAME                          AGE
# kserve-llm-isvc-vllm-engine   20h
```

**Note:** Metrics have a `kserve_` prefix (e.g., `kserve_vllm:prompt_tokens_total`) due to metric relabeling in the PodMonitor.

### Step 2.2: Deploy Tenant Prometheus


```bash
# Apply tenant Prometheus (creates namespace, SA, ConfigMap, Deployment, Service, Route)
oc apply -f 04-tenant-prometheus.yaml

# Wait for Prometheus to be ready
oc wait --for=condition=available deployment/tenant-a-prometheus \
  -n tenant-a-monitoring --timeout=300s

# Verify Prometheus pod is running
oc get pods -n tenant-a-monitoring
```

**Verify federation is working:**

```bash
# Get Prometheus pod name
PROM_POD=$(oc get pod -n tenant-a-monitoring -l app=tenant-a-prometheus -o jsonpath='{.items[0].metadata.name}')

# Check federation target health
oc exec -n tenant-a-monitoring $PROM_POD -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' | \
  grep -A 5 '"federate-user-workload"'

# Should show: "health":"up"

# List collected vLLM metrics
oc exec -n tenant-a-monitoring $PROM_POD -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | \
  grep kserve_vllm

# Should show 50+ kserve_vllm metrics
```

### Step 2.3: Load Dashboards

**IMPORTANT: Apply dashboards BEFORE deploying Grafana** because the Grafana deployment references the dashboard ConfigMap.

```bash
# Apply dashboard configuration (creates dashboard ConfigMaps)
oc apply -f 03-grafana-dashboards.yaml
```

### Step 2.4: Deploy Grafana with Tenant Prometheus Datasource

**Deploy Grafana (includes datasource config pointing to tenant Prometheus):**

```bash
# Apply Grafana deployment (includes datasource, provisioning configs)
oc apply -f 05-grafana-with-tenant-prometheus.yaml

# Wait for Grafana to be ready
oc wait --for=condition=available deployment/tenant-a-grafana \
  -n tenant-a-monitoring --timeout=300s

# Verify Grafana pod is running
oc get pods -n tenant-a-monitoring
```

### Step 2.5: Access Grafana

**Get Grafana URL and credentials:**

```bash
# Get the route URL
GRAFANA_URL=$(oc get route tenant-a-grafana -n tenant-a-monitoring -o jsonpath='{.spec.host}')
echo "Grafana URL: https://$GRAFANA_URL"

# Get admin credentials
echo "Username: admin"
echo "Password: changeme-please"
```

**Access the dashboard:**
1. Open the Grafana URL in your browser: `https://$GRAFANA_URL`
2. Login with credentials (username: admin, password: changeme-please)
3. Click "Dashboards" (left sidebar)
4. You should see "Tenant A - Model Usage Overview"
5. Click to open it

**Dashboard panels:**
- Request Rate (success and failure)
- Token Throughput (prompt and generation)
- Total Tokens Today
- Total Requests Today
- P95 Time to First Token (TTFT)
- P95 Inter-Token Latency (ITL)
- GPU Cache Utilization
- Queue Depth (running and waiting requests)

**Tenant A Setup Complete!**

---

## Phase 3: Tenant B Administrator Setup

Tenant B follows the same process as Tenant A.

```bash
# Login as Tenant B admin
oc login --token=<bob-jwt-token> --server=https://api.CLUSTER_DOMAIN:6443

# Switch to tenant-b directory
cd ../tenant-b/

# Step 1: Deploy tenant Prometheus
oc apply -f 04-tenant-prometheus.yaml
oc wait --for=condition=available deployment/tenant-b-prometheus \
  -n tenant-b-monitoring --timeout=300s

# Step 2: Load dashboards (BEFORE Grafana deployment)
oc apply -f 03-grafana-dashboards.yaml

# Step 3: Deploy Grafana with tenant Prometheus datasource
oc apply -f 05-grafana-with-tenant-prometheus.yaml
oc wait --for=condition=available deployment/tenant-b-grafana \
  -n tenant-b-monitoring --timeout=300s

# Get Grafana credentials and URL
GRAFANA_URL=$(oc get route tenant-b-grafana -n tenant-b-monitoring -o jsonpath='{.spec.host}')

echo "Grafana URL: https://$GRAFANA_URL"
echo "Username: admin"
echo "Password: changeme-please"
```

**Tenant B Setup Complete!**

---

