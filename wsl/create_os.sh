#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Installing OpenSearch Operator on Kubernetes${NC}"
echo ""

# Prompt for namespace
read -p "Enter namespace (default: opensearch): " OS_NAMESPACE
OS_NAMESPACE=${OS_NAMESPACE:-opensearch}

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Namespace: $OS_NAMESPACE"
echo ""

read -p "Continue with OpenSearch operator installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Create namespace
echo ""
echo -e "${GREEN}Step 1: Creating namespace ${OS_NAMESPACE}...${NC}"
kubectl create namespace ${OS_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Add Helm repo
echo ""
echo -e "${GREEN}Step 2: Adding Helm repository...${NC}"
helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/
helm repo update

# Install operator
echo ""
echo -e "${GREEN}Step 3: Installing OpenSearch operator...${NC}"
if ! helm list -n ${OS_NAMESPACE} | grep -q opensearch-operator; then
    helm install opensearch-operator opensearch-operator/opensearch-operator --namespace ${OS_NAMESPACE}

    echo "Waiting for operator deployment to be created..."

    # Wait for deployment to be created
    for i in {1..24}; do
        if kubectl get deployment -n ${OS_NAMESPACE} -l app.kubernetes.io/name=opensearch-operator &> /dev/null; then
            echo "  Operator deployment created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for operator deployment${NC}"
            echo "Check with: kubectl get all -n ${OS_NAMESPACE}"
            exit 1
        fi
        sleep 5
    done

    # Wait for pods to be created
    echo "Waiting for operator pods..."
    for i in {1..24}; do
        POD_COUNT=$(kubectl get pods -n ${OS_NAMESPACE} -l app.kubernetes.io/name=opensearch-operator --no-headers 2>/dev/null | wc -l)
        if [ "$POD_COUNT" -gt 0 ]; then
            echo "  Operator pod(s) created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for operator pods${NC}"
            kubectl get all -n ${OS_NAMESPACE}
            exit 1
        fi
        sleep 5
    done

    # Wait for pods to be ready
    echo "Waiting for operator to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=opensearch-operator -n ${OS_NAMESPACE} --timeout=180s

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
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenSearch Operator Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Namespace: ${OS_NAMESPACE}${NC}"
echo ""
echo "Verifying installation:"
kubectl get pods -n ${OS_NAMESPACE}
kubectl get deployment -n ${OS_NAMESPACE}

# Get host IP address
HOST_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Create opensearch-cluster.yaml with your cluster configuration"
echo "   Ensure services are configured as NodePort for permanent access:"
echo "   - OpenSearch service: NodePort 30200"
echo "   - Dashboard service: NodePort 30601"
echo "2. Deploy: kubectl apply -f opensearch-cluster.yaml"
echo "3. Monitor: kubectl get pods -n opensearch -w"
echo ""
echo -e "${YELLOW}Access OpenSearch (after cluster deployment):${NC}"
echo "  Direct access: http://${HOST_IP}:30200"
echo "  curl -k -u admin:password http://${HOST_IP}:30200"
echo ""
echo -e "${YELLOW}Access Dashboards (after cluster deployment):${NC}"
echo "  Direct access: http://${HOST_IP}:30601"
echo ""
echo -e "${YELLOW}Note:${NC}"
echo "  Services will be exposed as NodePort and permanently accessible"
echo "  No port-forwarding required!"
echo ""

# Add monitoring info if monitoring stack is installed
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    echo -e "${YELLOW}Prometheus Monitoring:${NC}"
    echo "  OpenSearch exposes Prometheus metrics on the /_prometheus endpoint"
    echo "  To enable monitoring for your cluster, add a ServiceMonitor after deployment:"
    echo ""
    echo "  kubectl apply -f - <<EOF"
    echo "  apiVersion: monitoring.coreos.com/v1"
    echo "  kind: ServiceMonitor"
    echo "  metadata:"
    echo "    name: opensearch-metrics"
    echo "    namespace: opensearch"
    echo "  spec:"
    echo "    selector:"
    echo "      matchLabels:"
    echo "        app: opensearch-cluster  # Update to match your cluster name"
    echo "    endpoints:"
    echo "    - port: http"
    echo "      path: /_prometheus/metrics"
    echo "      interval: 30s"
    echo "  EOF"
    echo ""
fi

exit 0
