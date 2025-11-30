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

# Wait for the cluster pods to be ready before creating monitoring
echo ""
echo -e "${GREEN}Step 5: Waiting for MongoDB pods to be ready...${NC}"
echo "Waiting for cluster to start (this may take 1-2 minutes)..."

# Wait for all expected pods to exist
echo "Waiting for all ${MONGO_REPLICAS} pod(s) to be created..."
for i in {1..120}; do
    POD_COUNT=$(kubectl get pods -n ${MONGO_NAMESPACE} -l app=${MONGO_CLUSTER_NAME}-svc --no-headers 2>/dev/null | wc -l)
    if [ "$POD_COUNT" -ge "${MONGO_REPLICAS}" ]; then
        echo "All ${MONGO_REPLICAS} pod(s) detected."
        break
    fi
    if [ $i -eq 120 ]; then
        echo -e "${YELLOW}Warning: Only $POD_COUNT of ${MONGO_REPLICAS} pods appeared. Continuing...${NC}"
    fi
    sleep 2
done

# Wait for all pods to be ready and running
echo "Waiting for all pods to be ready (Running + Ready condition)..."
WAIT_SUCCESS=false
for i in {1..120}; do
    # Get count of Running pods (use || true to prevent set -e from exiting)
    READY_COUNT=$(kubectl get pods -n ${MONGO_NAMESPACE} -l app=${MONGO_CLUSTER_NAME}-svc --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [ "$READY_COUNT" -ge "${MONGO_REPLICAS}" ]; then
        # Double-check with kubectl wait (protected from set -e)
        if kubectl wait --for=condition=ready pod -l app=${MONGO_CLUSTER_NAME}-svc -n ${MONGO_NAMESPACE} --timeout=10s >/dev/null 2>&1; then
            echo "All ${MONGO_REPLICAS} pod(s) are ready!"
            WAIT_SUCCESS=true
            break
        fi
    fi

    # Show progress every 10 seconds
    if [ $((i % 5)) -eq 0 ]; then
        echo "  $READY_COUNT of ${MONGO_REPLICAS} pod(s) ready..."
    fi
    sleep 2
done

if [ "$WAIT_SUCCESS" = false ]; then
    echo -e "${YELLOW}Warning: Not all pods became ready within the timeout period.${NC}"
    echo -e "${YELLOW}ServiceMonitor may not be created successfully. Check pod status with:${NC}"
    echo -e "${YELLOW}  kubectl get pods -n ${MONGO_NAMESPACE}${NC}"
fi

# Step 6: Configure monitoring
echo ""
echo -e "${GREEN}Step 6: Configuring monitoring...${NC}"

# Check if ServiceMonitor CRD exists
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    MONITORING_INSTALLED=true
    echo "Monitoring stack detected. Creating ServiceMonitor..."
else
    MONITORING_INSTALLED=false
    echo -e "${YELLOW}Note: Monitoring stack not yet installed.${NC}"
    echo "Creating monitoring configurations that will activate when monitoring is installed..."
fi

# Deploy MongoDB exporter AFTER pods are ready
# This prevents issues with the exporter connecting to MongoDB
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    # Deploy MongoDB exporter
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-exporter
  namespace: ${MONGO_NAMESPACE}
  labels:
    app: mongodb-exporter
spec:
  ports:
  - name: metrics
    port: 9216
    targetPort: 9216
    protocol: TCP
  selector:
    app: mongodb-exporter
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb-exporter
  namespace: ${MONGO_NAMESPACE}
  labels:
    app: mongodb-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongodb-exporter
  template:
    metadata:
      labels:
        app: mongodb-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9216"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: mongodb-exporter
        image: percona/mongodb_exporter:0.40
        args:
        - --mongodb.uri=mongodb://admin:\$(MONGODB_PASSWORD)@${MONGO_CLUSTER_NAME}-svc.${MONGO_NAMESPACE}.svc.cluster.local:27017/admin?replicaSet=${MONGO_CLUSTER_NAME}
        - --discovering-mode
        - --collect-all
        env:
        - name: MONGODB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${MONGO_CLUSTER_NAME}-admin-password
              key: password
        ports:
        - name: metrics
          containerPort: 9216
        livenessProbe:
          httpGet:
            path: /
            port: 9216
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 9216
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mongodb-exporter
  namespace: ${MONGO_NAMESPACE}
  labels:
    app: mongodb-exporter
    release: monitoring
spec:
  selector:
    matchLabels:
      app: mongodb-exporter
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
EOF

    if [ "$MONITORING_INSTALLED" = true ]; then
        echo "MongoDB monitoring configured and active."
        echo "  - MongoDB exporter deployed"
        echo "  - ServiceMonitor created for Prometheus scraping"
    else
        echo -e "${YELLOW}ServiceMonitor resources created successfully.${NC}"
        echo -e "${YELLOW}Metrics collection will start automatically when you run ./create_mon.sh${NC}"
    fi
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
echo "  kubectl get mongodbcommunity -n ${MONGO_NAMESPACE}"
echo "  kubectl get pods -n ${MONGO_NAMESPACE}"
echo "  kubectl get pvc -n ${MONGO_NAMESPACE}"
echo ""
echo -e "${YELLOW}Access MongoDB:${NC}"
echo "  kubectl exec -it ${MONGO_CLUSTER_NAME}-0 -n ${MONGO_NAMESPACE} -- mongosh -u admin -p"
echo ""
echo -e "${YELLOW}Monitor cluster status:${NC}"
echo "  kubectl get mongodbcommunity -n ${MONGO_NAMESPACE} -w"
echo ""

# Add Grafana dashboard info if monitoring is installed
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    HOST_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo -e "${YELLOW}Grafana Dashboard:${NC}"
    echo "  1. Access Grafana at http://${HOST_IP}:30000"
    echo ""
    echo "  2. In Grafana, go to Dashboards > Import"
    echo "  3. Click 'Upload JSON file'"
    echo "  4. Select: ${SCRIPT_DIR}/MongoDB_Percona_Grafana.json"
    echo "  5. Choose Prometheus datasource and click Import"
    echo ""
fi

exit 0
