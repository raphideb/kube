kubectl port-forward -n mongodb svc/raphi-mongodb-svc 27017:27017 &
kubectl port-forward -n postgres svc/pg-raphi-rw 54320:5432 &
