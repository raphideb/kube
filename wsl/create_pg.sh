#!/bin/bash

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}PostgreSQL Deployment on Kubernetes${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found. Please install Kubernetes first.${NC}"
    echo "Run ./create_kube.sh to set up Kubernetes cluster."
    exit 1
fi

# Check if cluster is running
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Kubernetes cluster is not running.${NC}"
    echo "Run ./create_kube.sh to set up Kubernetes cluster."
    exit 1
fi

# Prompt for user inputs
read -p "Enter PostgreSQL cluster name (default: postgres-cluster): " PG_CLUSTER_NAME
PG_CLUSTER_NAME=${PG_CLUSTER_NAME:-postgres-cluster}

read -p "Enter namespace (default: postgres): " PG_NAMESPACE
PG_NAMESPACE=${PG_NAMESPACE:-postgres}

read -p "Enter PostgreSQL storage size (default: 20Gi): " PG_STORAGE
PG_STORAGE=${PG_STORAGE:-20Gi}

read -p "Enter PostgreSQL replica count (default: 1): " PG_REPLICAS
PG_REPLICAS=${PG_REPLICAS:-1}

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Cluster Name: $PG_CLUSTER_NAME"
echo "Namespace: $PG_NAMESPACE"
echo "Storage: $PG_STORAGE"
echo "Replicas: $PG_REPLICAS"
echo ""

read -p "Continue with PostgreSQL installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Step 1: Creating namespaces...${NC}"
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace 'postgres' created (for operator)."
kubectl create namespace ${PG_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace '${PG_NAMESPACE}' created (for database cluster)."

echo ""
echo -e "${GREEN}Step 2: Installing CloudNativePG operator...${NC}"
if ! helm list -n postgres | grep -q cnpg-operator; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update
    helm install cnpg-operator cnpg/cloudnative-pg --namespace postgres

    echo "Waiting for CloudNativePG operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n postgres --timeout=180s
    echo "CloudNativePG operator installed in 'postgres' namespace."
    echo "Installing cnpg plugin"
    curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin
else
    echo "CloudNativePG operator already installed in 'postgres' namespace."
fi

echo ""
echo -e "${GREEN}Step 3: Deploying PostgreSQL cluster ${PG_CLUSTER_NAME}...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${PG_CLUSTER_NAME}
  namespace: ${PG_NAMESPACE}
spec:
  instances: ${PG_REPLICAS}
  monitoring:
    enablePodMonitor: false
  storage:
    size: ${PG_STORAGE}
    storageClass: local-path
EOF

echo "PostgreSQL cluster deployment initiated."

# Wait for the cluster pods to be ready before creating PodMonitor
echo ""
echo -e "${GREEN}Step 4: Waiting for PostgreSQL pods to be ready...${NC}"
echo "Waiting for cluster to start (this may take 1-2 minutes)..."

# Wait for all expected pods to exist
echo "Waiting for all ${PG_REPLICAS} pod(s) to be created..."
for i in {1..120}; do
    POD_COUNT=$(kubectl get pods -n ${PG_NAMESPACE} -l cnpg.io/cluster=${PG_CLUSTER_NAME} --no-headers 2>/dev/null | wc -l | head -1)
    POD_COUNT=${POD_COUNT:-0}
    if [ "$POD_COUNT" -ge "${PG_REPLICAS}" ]; then
        echo "All ${PG_REPLICAS} pod(s) detected."
        break
    fi
    if [ $i -eq 120 ]; then
        echo -e "${YELLOW}Warning: Only $POD_COUNT of ${PG_REPLICAS} pods appeared. Continuing...${NC}"
    fi
    sleep 2
done

# Wait for all pods to be ready and running
echo "Waiting for all pods to be ready (Running + Ready condition)..."
WAIT_SUCCESS=false
for i in {1..120}; do
    # Get count of Running pods (use || echo "0" to prevent set -e from exiting)
    READY_COUNT=$(kubectl get pods -n ${PG_NAMESPACE} -l cnpg.io/cluster=${PG_CLUSTER_NAME} --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    READY_COUNT=$(echo "$READY_COUNT" | head -1)
    READY_COUNT=${READY_COUNT:-0}

    if [ "$READY_COUNT" -ge "${PG_REPLICAS}" ]; then
        # Double-check with kubectl wait (protected from set -e)
        if kubectl wait --for=condition=ready pod -l cnpg.io/cluster=${PG_CLUSTER_NAME} -n ${PG_NAMESPACE} --timeout=10s >/dev/null 2>&1; then
            echo "All ${PG_REPLICAS} pod(s) are ready!"
            WAIT_SUCCESS=true
            break
        fi
    fi

    # Show progress every 10 seconds
    if [ $((i % 5)) -eq 0 ]; then
        echo "  $READY_COUNT of ${PG_REPLICAS} pod(s) ready..."
    fi
    sleep 2
done

if [ "$WAIT_SUCCESS" = false ]; then
    echo -e "${YELLOW}Warning: Not all pods became ready within the timeout period.${NC}"
    echo -e "${YELLOW}PodMonitor may not be created successfully. Check pod status with:${NC}"
    echo -e "${YELLOW}  kubectl get pods -n ${PG_NAMESPACE}${NC}"
fi

# Step 5: Configure monitoring
echo ""
echo -e "${GREEN}Step 5: Configuring monitoring...${NC}"

# Check if PodMonitor CRD exists
if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
    MONITORING_INSTALLED=true
    echo "Monitoring stack detected. Creating PodMonitors..."
else
    MONITORING_INSTALLED=false
    echo -e "${YELLOW}Note: Monitoring stack not yet installed.${NC}"
    echo "Creating PodMonitor configurations that will activate when monitoring is installed..."
fi

# Create PodMonitor for the PostgreSQL cluster AFTER pods are ready
# This prevents silent rejection by the kube-prometheus-stack admission webhook
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ${PG_CLUSTER_NAME}
  namespace: ${PG_NAMESPACE}
  labels:
    cnpg.io/cluster: ${PG_CLUSTER_NAME}
spec:
  namespaceSelector:
    matchNames:
    - ${PG_NAMESPACE}
  selector:
    matchLabels:
      cnpg.io/cluster: ${PG_CLUSTER_NAME}
  podMetricsEndpoints:
  - port: metrics
    path: /metrics
    interval: 30s
EOF

# Always create PodMonitor for the CloudNativePG operator (if not in postgres namespace)
# Only create if we're deploying to a different namespace than postgres
if [ "${PG_NAMESPACE}" != "postgres" ]; then
    # Check if operator PodMonitor already exists
    if ! kubectl get podmonitor cnpg-operator -n postgres &> /dev/null; then
        cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator
  namespace: postgres
  labels:
    app.kubernetes.io/name: cloudnative-pg
spec:
  namespaceSelector:
    matchNames:
    - postgres
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
  - port: metrics
EOF
    fi
fi

if [ "$MONITORING_INSTALLED" = true ]; then
    echo "PostgreSQL monitoring configured and active."
    echo "  - Cluster PodMonitor created in ${PG_NAMESPACE} namespace"
    [ "${PG_NAMESPACE}" != "postgres" ] && echo "  - Operator PodMonitor verified in postgres namespace"
else
    echo -e "${YELLOW}PodMonitor resources created successfully.${NC}"
    echo -e "${YELLOW}Metrics collection will start automatically when you run ./create_mon.sh${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}PostgreSQL Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Cluster: ${PG_CLUSTER_NAME}${NC}"
echo -e "${YELLOW}Namespace: ${PG_NAMESPACE}${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get clusters -n ${PG_NAMESPACE}"
echo "  kubectl get pods -n ${PG_NAMESPACE}"
echo "  kubectl get pvc -n ${PG_NAMESPACE}"
echo ""
echo -e "${YELLOW}Access PostgreSQL:${NC}"
echo "  kubectl cnpg psql ${PG_CLUSTER_NAME} -n ${PG_NAMESPACE}"
echo "  or: kubectl exec -it ${PG_CLUSTER_NAME}-1 -n ${PG_NAMESPACE} -- psql -U postgres"
echo ""
echo -e "${YELLOW}Monitor cluster status:${NC}"
echo "  kubectl get clusters -n ${PG_NAMESPACE} -w"
echo ""

# Add Grafana dashboard info if monitoring is installed
if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
    HOST_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Grafana Dashboard:${NC}"
    echo "  1. Access Grafana at http://${HOST_IP}:30000"
    echo ""
    echo "  2. In Grafana, go to Dashboards > Import"
    echo "  3. Enter dashboard ID: 20417 (CloudNativePG)"
    echo "  4. Select Prometheus datasource and click Import"
    echo ""
fi

exit 0
