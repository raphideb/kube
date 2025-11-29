#!/bin/bash

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}MongoDB Deployment on Kubernetes${NC}"
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
read -p "Enter MongoDB cluster name (default: mongodb-cluster): " MONGO_CLUSTER_NAME
MONGO_CLUSTER_NAME=${MONGO_CLUSTER_NAME:-mongodb-cluster}

read -p "Enter namespace (default: mongodb): " MONGO_NAMESPACE
MONGO_NAMESPACE=${MONGO_NAMESPACE:-mongodb}

read -p "Enter MongoDB storage size (default: 20Gi): " MONGO_STORAGE
MONGO_STORAGE=${MONGO_STORAGE:-20Gi}

read -p "Enter MongoDB replica count (default: 1): " MONGO_REPLICAS
MONGO_REPLICAS=${MONGO_REPLICAS:-1}

read -sp "Enter MongoDB admin password: " MONGO_PASSWORD
echo ""

if [ -z "$MONGO_PASSWORD" ]; then
    echo -e "${RED}MongoDB password cannot be empty!${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Cluster Name: $MONGO_CLUSTER_NAME"
echo "Namespace: $MONGO_NAMESPACE"
echo "Storage: $MONGO_STORAGE"
echo "Replicas: $MONGO_REPLICAS"
echo ""

read -p "Continue with MongoDB installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Step 1: Creating namespace ${MONGO_NAMESPACE}...${NC}"
kubectl create namespace ${MONGO_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace created."

echo ""
echo -e "${GREEN}Step 2: Installing MongoDB operator...${NC}"
if ! helm list -n ${MONGO_NAMESPACE} | grep -q mongodb-operator; then
    helm repo add mongodb https://mongodb.github.io/helm-charts
    helm repo update
    helm install mongodb-operator mongodb/community-operator --namespace ${MONGO_NAMESPACE}

    echo "Waiting for MongoDB operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mongodb-kubernetes-operator -n ${MONGO_NAMESPACE} --timeout=180s || true
    echo "MongoDB operator installed."
else
    echo "MongoDB operator already installed."
fi

echo ""
echo -e "${GREEN}Step 3: Creating MongoDB admin password secret...${NC}"
kubectl create secret generic ${MONGO_CLUSTER_NAME}-admin-password \
    --from-literal="password=${MONGO_PASSWORD}" \
    --namespace ${MONGO_NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "${GREEN}Step 4: Deploying MongoDB cluster ${MONGO_CLUSTER_NAME}...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: ${MONGO_CLUSTER_NAME}
  namespace: ${MONGO_NAMESPACE}
spec:
  members: ${MONGO_REPLICAS}
  type: ReplicaSet
  version: "7.0.0"
  security:
    authentication:
      modes: ["SCRAM"]
  users:
    - name: admin
      db: admin
      passwordSecretRef:
        name: ${MONGO_CLUSTER_NAME}-admin-password
      roles:
        - name: clusterAdmin
          db: admin
        - name: userAdminAnyDatabase
          db: admin
      scramCredentialsSecretName: ${MONGO_CLUSTER_NAME}-admin-scram
  statefulSet:
    spec:
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: local-path
            resources:
              requests:
                storage: ${MONGO_STORAGE}
EOF

echo "MongoDB cluster deployment initiated."

# Step 5: Configure monitoring if installed
echo ""
echo -e "${GREEN}Step 5: Configuring monitoring (if installed)...${NC}"
if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ${MONGO_CLUSTER_NAME}-monitor
  namespace: ${MONGO_NAMESPACE}
  labels:
    app: mongodb
spec:
  selector:
    matchLabels:
      app: ${MONGO_CLUSTER_NAME}-svc
  podMetricsEndpoints:
  - port: prometheus
    path: /metrics
EOF
    echo "MongoDB monitoring configured."
    echo "  - Cluster PodMonitor created"
else
    echo -e "${YELLOW}Warning: Monitoring stack not installed. Metrics collection disabled.${NC}"
    echo -e "${YELLOW}Install monitoring with ./create_mon.sh to enable metrics collection.${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}MongoDB Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Cluster: ${MONGO_CLUSTER_NAME}${NC}"
echo -e "${YELLOW}Namespace: ${MONGO_NAMESPACE}${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get mongodb -n ${MONGO_NAMESPACE}"
echo "  kubectl get pods -n ${MONGO_NAMESPACE}"
echo "  kubectl get pvc -n ${MONGO_NAMESPACE}"
echo ""
echo -e "${YELLOW}Access MongoDB:${NC}"
echo "  kubectl exec -it ${MONGO_CLUSTER_NAME}-0 -n ${MONGO_NAMESPACE} -- mongosh -u admin -p"
echo ""
echo -e "${YELLOW}Monitor cluster status:${NC}"
echo "  kubectl get mongodb -n ${MONGO_NAMESPACE} -w"
echo ""

# Add Grafana dashboard info if monitoring is installed
if kubectl get crd podmonitors.monitoring.coreos.com &> /dev/null; then
    HOST_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Grafana Dashboards:${NC}"
    echo "  1. Access Grafana at http://${HOST_IP}:30000"
    echo ""
    echo "  2. In Grafana, go to Dashboards > Import"
    echo "  3. Choose one of these MongoDB dashboards:"
    echo "     - Dashboard ID: 2583 (MongoDB Overview)"
    echo "     - Dashboard ID: 7353 (MongoDB Exporter)"
    echo "     - Dashboard ID: 12079 (MongoDB)"
    echo "  4. Select Prometheus datasource and click Import"
    echo ""
fi

exit 0
