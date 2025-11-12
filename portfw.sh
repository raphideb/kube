kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
kubectl port-forward -n opensearch svc/opensearch-cluster 9200:9200 &
kubectl port-forward -n opensearch svc/opensearch-cluster-dashboards 5601:5601 &
