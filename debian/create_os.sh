#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Installing OpenSearch on Kubernetes${NC}"
echo ""

# Create namespace
echo -e "${GREEN}Step 1: Creating namespace...${NC}"
kubectl create namespace opensearch --dry-run=client -o yaml | kubectl apply -f -

# Add Helm repo
echo ""
echo -e "${GREEN}Step 2: Adding Helm repository...${NC}"
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm repo update

# Install operator
echo ""
echo -e "${GREEN}Step 3: Installing OpenSearch operator...${NC}"
if ! helm list -n opensearch | grep -q opensearch-operator; then
    helm install opensearch-operator opensearch-operator/opensearch-operator --namespace opensearch
    
    echo "Waiting for operator deployment to be created..."
    
    # Wait for deployment to be created
    for i in {1..24}; do
        if kubectl get deployment -n opensearch -l app.kubernetes.io/name=opensearch-operator &> /dev/null; then
            echo "  Operator deployment created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for operator deployment${NC}"
            echo "Check with: kubectl get all -n opensearch"
            exit 1
        fi
        sleep 5
    done
    
    # Wait for pods to be created
    echo "Waiting for operator pods..."
    for i in {1..24}; do
        POD_COUNT=$(kubectl get pods -n opensearch -l app.kubernetes.io/name=opensearch-operator --no-headers 2>/dev/null | wc -l)
        if [ "$POD_COUNT" -gt 0 ]; then
            echo "  Operator pod(s) created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for operator pods${NC}"
            kubectl get all -n opensearch
            exit 1
        fi
        sleep 5
    done
    
    # Wait for pods to be ready
    echo "Waiting for operator to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=opensearch-operator -n opensearch --timeout=180s
    
    echo "Operator ready."
else
    echo "Operator already installed."
fi

# Configure kernel parameter
echo ""
echo -e "${GREEN}Step 4: Configuring vm.max_map_count...${NC}"
sudo sysctl -w vm.max_map_count=262144
if ! grep -q "vm.max_map_count=262144" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
fi

echo ""
echo -e "${GREEN}OpenSearch Operator installed successfully!${NC}"
echo ""
echo "Verifying installation:"
kubectl get pods -n opensearch
kubectl get deployment -n opensearch

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Create opensearch-cluster.yaml with your cluster configuration"
echo "2. Deploy: kubectl apply -f opensearch-cluster.yaml"
echo "3. Monitor: kubectl get pods -n opensearch -w"
echo ""
echo -e "${YELLOW}Access OpenSearch:${NC}"
echo "  kubectl port-forward -n opensearch svc/my-opensearch-cluster 9200:9200"
echo "  curl -k -u admin:password https://localhost:9200"
echo ""
echo -e "${YELLOW}Access Dashboards:${NC}"
echo "  kubectl port-forward -n opensearch svc/my-opensearch-cluster-dashboards 5601:5601"
echo "  Open http://localhost:5601"
echo ""
exit 0
