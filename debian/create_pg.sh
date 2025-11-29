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
read -p "Enter PostgreSQL storage size (default: 20Gi): " PG_STORAGE
PG_STORAGE=${PG_STORAGE:-20Gi}

read -p "Enter PostgreSQL replica count (default: 3): " PG_REPLICAS
PG_REPLICAS=${PG_REPLICAS:-3}

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "PostgreSQL Storage: $PG_STORAGE (replicas: $PG_REPLICAS)"
echo ""

read -p "Continue with PostgreSQL installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Step 1: Creating postgres namespace...${NC}"
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace created."

echo ""
echo -e "${GREEN}Step 2: Installing CloudNativePG operator...${NC}"
if ! helm list -n postgres | grep -q cnpg-operator; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update
    helm install cnpg-operator cnpg/cloudnative-pg --namespace postgres

    echo "Waiting for CloudNativePG operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n postgres --timeout=180s
    echo "CloudNativePG operator installed."
    echo "Installing cnpg plugin"
    curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin
else
    echo "CloudNativePG operator already installed."
fi

echo ""
echo -e "${GREEN}Step 3: Deploying PostgreSQL cluster...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: postgres
spec:
  instances: ${PG_REPLICAS}
  monitoring:
    enablePodMonitor: false
  storage:
    size: ${PG_STORAGE}
    storageClass: local-path
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: postgres-cluster
  namespace: postgres
  labels:
    cnpg.io/cluster: postgres-cluster
spec:
  namespaceSelector:
    matchNames:
    - postgres
  selector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
  podMetricsEndpoints:
  - port: metrics
    path: /metrics
    interval: 30s
EOF

echo "PostgreSQL cluster deployment initiated."

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}PostgreSQL Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get clusters -n postgres"
echo "  kubectl get pods -n postgres"
echo "  kubectl get pvc -n postgres"
echo ""
echo -e "${YELLOW}Access PostgreSQL:${NC}"
echo "  kubectl cnpg psql postgres-cluster -n postgres"
echo "  or: kubectl exec -it postgres-cluster-1 -n postgres -- psql -U postgres"
echo ""
echo -e "${YELLOW}Monitor cluster status:${NC}"
echo "  kubectl get clusters -n postgres -w"
echo ""
exit 0
