# Get the pod name and service to build connection string
POD_NAME=$(kubectl get pods -n oracle -l app=raphi-ora -o jsonpath='{.items[0].metadata.name}')
SVC_NAME=$(kubectl get svc -n oracle raphi-ora -o jsonpath='{.metadata.name}')

# Create a comprehensive secret for the observer
kubectl create secret generic oracle-observer-credentials \
  --from-literal=username=system \
  --from-literal=password=Homepw_12345 \
  --from-literal=connection_string="raphi-ora:1521/FREE" \
  -n oracle \
  --dry-run=client -o yaml | kubectl apply -f -
