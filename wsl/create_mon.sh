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
  service:
    type: NodePort
    nodePort: 30090
grafana:
  adminPassword: admin
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi
  service:
    type: NodePort
    nodePort: 30000
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

# Step 4: Get Grafana admin password
echo ""
echo -e "${GREEN}Step 4: Retrieving Grafana credentials...${NC}"
sleep 10  # Wait for secret to be created
GRAFANA_PASSWORD=$(kubectl get secret --namespace monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
echo "Grafana admin password: ${GRAFANA_PASSWORD}"

# Step 5: Get host IP address
HOST_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')

# Step 6: Print access instructions
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Monitoring Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Verify installation:${NC}"
echo "  kubectl get pods -n monitoring"
echo ""
echo -e "${YELLOW}Access Grafana:${NC}"
echo "  Open http://${HOST_IP}:30000 in your browser"
echo ""
echo -e "${YELLOW}Grafana Credentials:${NC}"
echo "  Username: admin"
echo "  Password: ${GRAFANA_PASSWORD}"
echo ""
echo -e "${YELLOW}Access Prometheus:${NC}"
echo "  Open http://${HOST_IP}:30090 in your browser"
echo ""
echo -e "${YELLOW}Note:${NC}"
echo "  Services are exposed as NodePort and permanently accessible"
echo "  No port-forwarding required!"
echo ""
echo -e "${YELLOW}HTTPS Configuration:${NC}"
echo "  Grafana is currently running on HTTP."
echo "  To enable HTTPS, you can:"
echo "  1. Use an Ingress controller with TLS (recommended for production)"
echo "  2. Configure Grafana's built-in HTTPS support"
echo "  See: https://grafana.com/docs/grafana/latest/setup-grafana/set-up-https/"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  Deploy databases with monitoring enabled:"
echo "    ./create_pg.sh      # PostgreSQL with CloudNativePG"
echo "    ./create_mongodb.sh # MongoDB"
echo "    ./create_oracle.sh  # Oracle 23c"
echo "    ./create_os.sh      # OpenSearch"
echo ""
echo "  Each script will automatically configure monitoring for its product."
echo ""
exit 0
