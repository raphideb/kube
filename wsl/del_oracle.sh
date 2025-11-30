#!/bin/bash

set -e

# Configuration Variables
NAMESPACE="oracle"
DB_NAME="oracle23"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}=== Oracle Database 23ai Free - Kubernetes Uninstallation ===${NC}"

# Step 1: Delete SingleInstanceDatabase resource
echo -e "\n${YELLOW}[1/8] Deleting SingleInstanceDatabase resource...${NC}"
kubectl delete singleinstancedatabase ${DB_NAME} -n ${NAMESPACE} --ignore-not-found=true

echo "Waiting for database resources to be cleaned up..."
sleep 10

# Step 2: Delete the namespace (this removes all pods, services, PVCs, secrets)
echo -e "\n${YELLOW}[2/8] Deleting namespace: ${NAMESPACE}...${NC}"
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

# Step 3: Delete Oracle Database Operator
echo -e "\n${YELLOW}[3/8] Deleting Oracle Database Operator...${NC}"
kubectl delete -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml --ignore-not-found=true

# Step 4: Delete RBAC resources
echo -e "\n${YELLOW}[4/8] Deleting cluster role bindings...${NC}"
kubectl delete -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml --ignore-not-found=true

echo -e "\n${YELLOW}[5/8] Deleting node RBAC...${NC}"
kubectl delete -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/node-rbac.yaml --ignore-not-found=true

# Step 5: Delete CRDs (optional - comment out if you want to keep CRDs)
echo -e "\n${YELLOW}[6/8] Deleting CRDs...${NC}"
kubectl delete crd singleinstancedatabases.database.oracle.com --ignore-not-found=true
kubectl delete crd autonomousdatabases.database.oracle.com --ignore-not-found=true
kubectl delete crd autonomousdatabasebackups.database.oracle.com --ignore-not-found=true
kubectl delete crd autonomousdatabaserestores.database.oracle.com --ignore-not-found=true
kubectl delete crd autonomouscontainerdatabases.database.oracle.com --ignore-not-found=true
kubectl delete crd dataguardbrokers.database.oracle.com --ignore-not-found=true
kubectl delete crd dbcssystems.database.oracle.com --ignore-not-found=true
kubectl delete crd oraclerestdataservices.database.oracle.com --ignore-not-found=true
kubectl delete crd shardingdatabases.database.oracle.com --ignore-not-found=true
kubectl delete crd databaseobservers.observability.oracle.com --ignore-not-found=true

# Step 6: Delete operator namespace
echo -e "\n${YELLOW}[7/8] Deleting operator namespace...${NC}"
kubectl delete namespace oracle-database-operator-system --ignore-not-found=true

# Step 7: Delete cert-manager (optional - comment out if you use cert-manager for other things)
echo -e "\n${YELLOW}[8/8] Deleting cert-manager...${NC}"
read -p "Do you want to delete cert-manager? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml --ignore-not-found=true
    echo "cert-manager deleted."
else
    echo "Skipping cert-manager deletion."
fi

echo -e "\n${GREEN}=== Uninstallation Complete ===${NC}"
echo ""
echo "All Oracle Database resources have been removed."
echo ""
echo "To verify cleanup:"
echo "  kubectl get all -n ${NAMESPACE}"
echo "  kubectl get pods -n oracle-database-operator-system"

