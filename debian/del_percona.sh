#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}Percona MongoDB Uninstall${NC}"
echo -e "${RED}========================================${NC}"
echo ""

# Prompt for namespace names
read -p "Enter operator namespace (default: percona-operator): " OPERATOR_NAMESPACE
OPERATOR_NAMESPACE=${OPERATOR_NAMESPACE:-percona-operator}

read -p "Enter database namespace (default: percona-mongodb): " MONGO_NAMESPACE
MONGO_NAMESPACE=${MONGO_NAMESPACE:-percona-mongodb}

echo ""
echo -e "${RED}WARNING: This will delete:${NC}"
echo "  - All Percona MongoDB clusters in namespace '${MONGO_NAMESPACE}'"
echo "  - All persistent volumes and data in namespace '${MONGO_NAMESPACE}'"
echo "  - The Percona MongoDB operator in namespace '${OPERATOR_NAMESPACE}'"
echo "  - Percona MongoDB CRDs (cluster-wide)"
echo ""

read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
if [[ ! $CONFIRM == "yes" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

# Step 1: Delete all PerconaServerMongoDB resources in the database namespace
echo -e "\n${YELLOW}[1/6] Deleting Percona MongoDB clusters...${NC}"
kubectl delete psmdb --all -n ${MONGO_NAMESPACE} --ignore-not-found=true
echo "Waiting for cluster resources to be cleaned up..."
sleep 10

# Step 2: Delete monitoring resources
echo -e "\n${YELLOW}[2/6] Deleting monitoring resources...${NC}"
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    kubectl delete servicemonitor percona-mongodb-exporter -n ${MONGO_NAMESPACE} --ignore-not-found=true
else
    echo "ServiceMonitor CRD not found, skipping."
fi
kubectl delete deployment percona-mongodb-exporter -n ${MONGO_NAMESPACE} --ignore-not-found=true
kubectl delete service percona-mongodb-exporter -n ${MONGO_NAMESPACE} --ignore-not-found=true
echo "Monitoring resources deleted."

# Step 3: Uninstall the Percona operator helm release
echo -e "\n${YELLOW}[3/6] Uninstalling Percona MongoDB operator...${NC}"
helm uninstall percona-mongodb-operator -n ${OPERATOR_NAMESPACE} 2>/dev/null || echo "Helm release not found, skipping."

# Step 4: Delete Percona MongoDB CRDs
echo -e "\n${YELLOW}[4/6] Deleting Percona MongoDB CRDs...${NC}"
kubectl delete crd perconaservermongodbs.psmdb.percona.com --ignore-not-found=true
kubectl delete crd perconaservermongodbbackups.psmdb.percona.com --ignore-not-found=true
kubectl delete crd perconaservermongodbrestores.psmdb.percona.com --ignore-not-found=true
echo "CRDs deleted."

# Step 5: Delete the database namespace
echo -e "\n${YELLOW}[5/6] Deleting database namespace '${MONGO_NAMESPACE}'...${NC}"
kubectl delete namespace ${MONGO_NAMESPACE} --ignore-not-found=true
echo "Database namespace deleted."

# Step 6: Delete the operator namespace
echo -e "\n${YELLOW}[6/6] Deleting operator namespace '${OPERATOR_NAMESPACE}'...${NC}"
kubectl delete namespace ${OPERATOR_NAMESPACE} --ignore-not-found=true
echo "Operator namespace deleted."

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Percona MongoDB Uninstall Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "To verify cleanup:"
echo "  kubectl get psmdb --all-namespaces"
echo "  kubectl get pods -n ${OPERATOR_NAMESPACE}"
echo "  kubectl get pods -n ${MONGO_NAMESPACE}"
echo ""
