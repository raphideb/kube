#!/bin/bash

set -e

# Configuration Variables
NAMESPACE="oracle"
DB_NAME="oracle23"
DB_PASSWORD="Homepw_12345"  # Change this!
STORAGE_CLASS="local-path"
STORAGE_SIZE="10Gi"
CERT_MANAGER_VERSION="v1.16.2"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Oracle Database 23ai Free - Kubernetes Deployment ===${NC}"

# Step 1: Install cert-manager
echo -e "\n${YELLOW}[1/9] Installing cert-manager...${NC}"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

echo "Waiting for cert-manager pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

echo "Waiting for cert-manager webhook to be ready (this may take up to 2 minutes)..."
sleep 60

# Verify webhook is accessible
until kubectl -n cert-manager get pods -l app.kubernetes.io/component=webhook --no-headers | grep -q Running; do
  echo "Waiting for cert-manager webhook pod to be running..."
  sleep 5
done

echo "Waiting an additional 30 seconds for webhook certificates to be generated..."
sleep 30

# Step 2: Install cluster role bindings
echo -e "\n${YELLOW}[2/9] Installing cluster role bindings...${NC}"
kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml

# Step 3: Install node RBAC (required for node access)
echo -e "\n${YELLOW}[3/9] Installing node RBAC...${NC}"
kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/node-rbac.yaml

# Step 4: Install Oracle Database Operator
echo -e "\n${YELLOW}[4/9] Installing Oracle Database Operator...${NC}"
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml; then
    echo "Oracle Database Operator installed successfully"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "Retrying in 30 seconds... (Attempt $RETRY_COUNT of $MAX_RETRIES)"
      sleep 30
    else
      echo -e "${RED}Failed to install Oracle Database Operator after $MAX_RETRIES attempts${NC}"
      exit 1
    fi
  fi
done

echo "Waiting for operator deployment to be created..."
sleep 15

# Step 5: Scale operator to 1 replica (avoid leader election issues)
echo -e "\n${YELLOW}[5/9] Scaling operator to 1 replica to avoid leader election issues...${NC}"
kubectl scale deployment oracle-database-operator-controller-manager \
  -n oracle-database-operator-system --replicas=1

# Step 6: Wait for operator to be ready
echo -e "\n${YELLOW}[6/9] Waiting for operator to be ready...${NC}"
kubectl wait --for=condition=ready pod -l control-plane=controller-manager \
  -n oracle-database-operator-system --timeout=300s

# Step 7: Create namespace for Oracle database
echo -e "\n${YELLOW}[7/9] Creating namespace: ${NAMESPACE}...${NC}"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 8: Create admin password secret
echo -e "\n${YELLOW}[8/9] Creating database admin secret...${NC}"
kubectl create secret generic db-admin-secret \
  --from-literal=oracle_pwd="${DB_PASSWORD}" \
  -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 9: Create SingleInstanceDatabase resource
echo -e "\n${YELLOW}[9/9] Creating SingleInstanceDatabase resource...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: database.oracle.com/v1alpha1
kind: SingleInstanceDatabase
metadata:
  name: ${DB_NAME}
  namespace: ${NAMESPACE}
spec:
  sid: FREE
  edition: free
  image:
    pullFrom: container-registry.oracle.com/database/free:latest
  adminPassword:
    secretName: db-admin-secret
    secretKey: oracle_pwd
  persistence:
    size: ${STORAGE_SIZE}
    storageClass: "${STORAGE_CLASS}"
    accessMode: ReadWriteOnce
  replicas: 1
EOF

# Step 10: Create credentials for monitoring
echo -e "\n${YELLOW}[10/10] Configuring monitoring...${NC}"

# Create a comprehensive secret for the observer
kubectl create secret generic ${DB_NAME}-observer-credentials \
  --from-literal=username=system \
  --from-literal=password=${DB_PASSWORD} \
  --from-literal=connection_string="${DB_NAME}:1521/FREE" \
  -n oracle \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy DatabaseObserver and ServiceMonitor if monitoring is installed
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    cat <<EOF | kubectl apply -f -
apiVersion: observability.oracle.com/v1alpha1
kind: DatabaseObserver
metadata:
  name: ${DB_NAME}-observer
  namespace: ${NAMESPACE}
  labels:
    database: ${DB_NAME}
spec:
  database:
    dbUser:
      secret: ${DB_NAME}-observer-credentials
      key: username
    dbPassword:
      secret: ${DB_NAME}-observer-credentials
      key: password
    dbConnectionString:
      secret: ${DB_NAME}-observer-credentials
      key: connection_string
  replicas: 1
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${DB_NAME}-metrics
  namespace: ${NAMESPACE}
  labels:
    app: ${DB_NAME}-observer
    database: ${DB_NAME}
spec:
  selector:
    matchLabels:
      app: ${DB_NAME}-observer
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
    relabelings:
    - targetLabel: database
      replacement: ${DB_NAME}
    - sourceLabels: [__meta_kubernetes_namespace]
      targetLabel: namespace
EOF
    echo "Oracle monitoring configured."
    echo "  - DatabaseObserver created"
    echo "  - ServiceMonitor created"
else
    echo -e "${YELLOW}Warning: Monitoring stack not installed. Metrics collection disabled.${NC}"
    echo -e "${YELLOW}Install monitoring with ./create_mon.sh to enable metrics collection.${NC}"
fi

echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo ""
echo "Database creation in progress. This may take several minutes..."
echo ""
echo "Monitor progress with:"
echo "  kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo "Check database status:"
echo "  kubectl get singleinstancedatabase ${DB_NAME} -n ${NAMESPACE}"
echo ""
echo "Once the pod is running (may take 5-10 minutes), connect with:"
echo "  POD_NAME=\$(kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME} -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl exec -it \$POD_NAME -n ${NAMESPACE} -- sqlplus sys/${DB_PASSWORD}@FREE as sysdba"
echo ""
echo "View logs:"
echo "  POD_NAME=\$(kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME} -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl logs -f \$POD_NAME -n ${NAMESPACE}"
echo ""

# Add Grafana dashboard info if monitoring is installed
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    echo -e "${YELLOW}Grafana Dashboard:${NC}"
    echo "  1. Access Grafana (if not already running):"
    echo "     kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
    echo ""
    echo "  2. Import the Oracle dashboard from this repository:"
    echo "     In Grafana, go to Dashboards > Import"
    echo "     Upload the file: OracleDB_Grafana.json"
    echo "     (Modified version of dashboard 13555 with database name selection)"
    echo ""
fi

