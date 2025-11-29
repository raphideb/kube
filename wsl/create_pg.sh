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
echo -e "${GREEN}Step 1: Creating namespace ${PG_NAMESPACE}...${NC}"
kubectl create namespace ${PG_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace created."

echo ""
echo -e "${GREEN}Step 2: Installing CloudNativePG operator...${NC}"
if ! helm list -n ${PG_NAMESPACE} | grep -q cnpg-operator; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update
    helm install cnpg-operator cnpg/cloudnative-pg --namespace ${PG_NAMESPACE}

    echo "Waiting for CloudNativePG operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n ${PG_NAMESPACE} --timeout=180s
    echo "CloudNativePG operator installed."
    echo "Installing cnpg plugin"
    curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin
else
    echo "CloudNativePG operator already installed."
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

# Step 4: Configure monitoring if installed
echo ""
echo -e "${GREEN}Step 4: Configuring monitoring (if installed)...${NC}"
if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
    # Create PodMonitor for the PostgreSQL cluster
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

    # Create PodMonitor for the CloudNativePG operator
    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator-${PG_NAMESPACE}
  namespace: ${PG_NAMESPACE}
  labels:
    app.kubernetes.io/name: cloudnative-pg
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
  - port: metrics
EOF

    echo "PostgreSQL monitoring configured."
    echo "  - Cluster PodMonitor created"
    echo "  - Operator PodMonitor created"
else
    echo -e "${YELLOW}Warning: Monitoring stack not installed. Metrics collection disabled.${NC}"
    echo -e "${YELLOW}Install monitoring with ./create_mon.sh to enable metrics collection.${NC}"
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
