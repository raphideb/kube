#!/bin/bash

# Usage: ./deploy-oracle.sh <db-name> <sid> <password>

DB_NAME=${1:-oracle-db}
SID=${2:-ORCL}
PASSWORD=${3:-DefaultPassword123}
NAMESPACE="oracle"

echo "Deploying Oracle Database: $DB_NAME with SID: $SID"

# Create password secret
kubectl create secret generic ${DB_NAME}-secret \
  --from-literal=oracle_pwd="${PASSWORD}" \
  -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy database
cat <<EOF | kubectl apply -f -
apiVersion: database.oracle.com/v1alpha1
kind: SingleInstanceDatabase
metadata:
  name: ${DB_NAME}
  namespace: ${NAMESPACE}
spec:
  sid: ${SID}
  edition: free
  image:
    pullFrom: container-registry.oracle.com/database/free:latest
  adminPassword:
    secretName: ${DB_NAME}-secret
    secretKey: oracle_pwd
  persistence:
    size: 10Gi
    storageClass: "local-path"
    accessMode: ReadWriteOnce
  replicas: 1
EOF

echo "Waiting for database to be created..."
sleep 30

# Create observer credentials
kubectl create secret generic ${DB_NAME}-observer-credentials \
  --from-literal=username=system \
  --from-literal=password="${PASSWORD}" \
  --from-literal=connection_string="${DB_NAME}:1521/${SID}" \
  -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy DatabaseObserver and ServiceMonitor
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

echo "Database ${DB_NAME} deployed with monitoring!"
echo "Connect with:"
echo "  POD_NAME=\$(kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME} -o jsonpath='{.items[0].metadata.name}')"
echo "  kubectl exec -it \$POD_NAME -n ${NAMESPACE} -- sqlplus system/${PASSWORD}@${SID} as sysdba"

