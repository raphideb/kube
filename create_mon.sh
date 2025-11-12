#!/bin/bash

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installing Prometheus & Grafana Stack${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 1: Create monitoring namespace
echo -e "${GREEN}Step 1: Creating monitoring namespace...${NC}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Add Helm repositories
echo ""
echo -e "${GREEN}Step 2: Adding Helm repositories...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
echo "Helm repositories added."

# Step 3: Install kube-prometheus-stack
echo ""
echo -e "${GREEN}Step 3: Installing kube-prometheus-stack...${NC}"
if ! helm list -n monitoring | grep -q kube-prometheus-stack; then
    cat <<EOF > /tmp/prometheus-values.yaml
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorSelector: {}
    podMonitorNamespaceSelector: {}
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
grafana:
  adminPassword: admin
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi
  service:
    type: ClusterIP
EOF

    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --values /tmp/prometheus-values.yaml

    echo "Waiting for kube-prometheus-stack components to be created..."
    
    # Wait for the deployment to be created
    for i in {1..24}; do
        if kubectl get deployment kube-prometheus-stack-operator -n monitoring &> /dev/null; then
            echo "  Prometheus Operator deployment created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for Prometheus Operator deployment${NC}"
            exit 1
        fi
        sleep 5
    done
    
    # Wait for operator pod to be ready
    echo "Waiting for Prometheus Operator to be ready..."
    kubectl wait --for=condition=ready pod -l app=kube-prometheus-stack-operator -n monitoring --timeout=180s
    
    # Wait for Prometheus statefulset to be created
    for i in {1..24}; do
        if kubectl get statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring &> /dev/null; then
            echo "  Prometheus StatefulSet created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${YELLOW}Warning: Prometheus StatefulSet not created yet${NC}"
        fi
        sleep 5
    done
    
    # Wait for Grafana deployment
    echo "Waiting for Grafana to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=180s
    
    echo "kube-prometheus-stack installed."
else
    echo "kube-prometheus-stack already installed."
fi

# Step 4: Enable monitoring for CloudNativePG
echo ""
echo -e "${GREEN}Step 4: Enabling monitoring for PostgreSQL cluster...${NC}"
if kubectl get cluster postgres-cluster -n postgres &> /dev/null; then
    kubectl patch cluster postgres-cluster -n postgres --type=merge -p '
spec:
  monitoring:
    enablePodMonitor: true
'
    echo "PostgreSQL monitoring enabled."
else
    echo -e "${YELLOW}Warning: postgres-cluster not found, skipping.${NC}"
fi

# Step 5: Create PodMonitor for MongoDB
echo ""
echo -e "${GREEN}Step 5: Creating PodMonitor for MongoDB...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: mongodb-cluster-monitor
  namespace: mongodb
  labels:
    app: mongodb
spec:
  selector:
    matchLabels:
      app: mongodb-cluster-svc
  podMetricsEndpoints:
  - port: prometheus
    path: /metrics
EOF
echo "MongoDB PodMonitor created."

# Step 6: Create PodMonitor for CloudNativePG Operator
echo ""
echo -e "${GREEN}Step 6: Creating PodMonitor for CloudNativePG operator...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator
  namespace: postgres
  labels:
    app.kubernetes.io/name: cloudnative-pg
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
  - port: metrics
EOF
echo "CNPG operator PodMonitor created."

# Step 7: Get Grafana admin password
echo ""
echo -e "${GREEN}Step 7: Retrieving Grafana credentials...${NC}"
sleep 10  # Wait for secret to be created
GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo "Grafana admin password: ${GRAFANA_PASSWORD}"

# Step 8: Print access instructions
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Monitoring Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Verify installation:${NC}"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get podmonitors --all-namespaces"
echo ""
echo -e "${YELLOW}Access Grafana:${NC}"
echo "  1. Port-forward Grafana service:"
echo "     kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
echo ""
echo "  2. Open http://localhost:3000 in your browser"
echo ""
echo -e "${YELLOW}Grafana Credentials:${NC}"
echo "  Username: admin"
echo "  Password: ${GRAFANA_PASSWORD}"
echo ""
echo -e "${YELLOW}Import CloudNativePG Dashboard:${NC}"
echo "  1. In Grafana, go to Dashboards > Import"
echo "  2. Enter dashboard ID: 20417"
echo "  3. Select Prometheus datasource"
echo "  4. Click Import"
echo ""
echo -e "${YELLOW}MongoDB Dashboards (choose one):${NC}"
echo "  - Dashboard ID: 2583 (MongoDB Overview)"
echo "  - Dashboard ID: 7353 (MongoDB Exporter)"
echo "  - Dashboard ID: 12079 (MongoDB)"
echo ""
echo -e "${YELLOW}Access Prometheus:${NC}"
echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
echo "  Open http://localhost:9090"
echo ""
echo -e "${YELLOW}Check metrics are being scraped:${NC}"
echo "  In Prometheus UI, go to Status > Targets"
echo "  You should see postgres and mongodb targets"
echo ""
exit 0
