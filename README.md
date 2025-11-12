# Scripts to setup a vanilla Kubernetes cluster in WSL
## Description
These scripts are used to setup the following:
1. Helm and Docker with cri-docker
2. Kubernetes cluster with persistent storage and Calico networking
3. CloudNative-PG operator with cnpg plugin and deployment of a sample DB
4. MongoDB operator and deployment of a sample DB
5. OpenSearch operator
6. Prometheus
7. Grafana

Plus yaml files for deploying:
- postgres cluster with grafana support 
- mongodb cluster (will add grafana later)
- opensearch cluster with dashboard

**Important**
When everything is running, on my machine WSL uses over 16GB of memory and swap needs to be disabled. If this is too much for your machine, consider using k3d or kind. 

## Installation
This assumes that you have a working WSL/Debian installation (I used Debian 12.11) and that you have downloaded all files into a directory in WSL. Everything can be executed as a normal user, sudo will be used where needed. 

If any packages (curl, wget) are missing that are not covered by the install script, install them manually.

1. Setup kubernetes
   ```
   ./create_kube.sh
   ```
   You might (probably will) run into problems that you need to figure out - best way to do that is to copy/paste the error into an AI prompt like perplexity. If for some reason you need to start from scratch, you can uninstall everything with this script:
   ```
   ./del_kube.sh
   ```
   And then run the installation again.
  
3. Install Prometheus & Grafana
   ```
   ./create_mon.sh
   ```
4. Install OpenSearch operator (optional)
   ```
   ./create_os.sh
   ```
5. Deploy OpenSearch cluster (optional)
   ```
   kubectl apply -f opensearch.yml
   ```
7. In a second window, forward the ports for Grafana, Prometheus and Dashboards. If you did not deploy OpenSearch, you need to edit the file first and then execute:
   ```
   ./portfw.sh
   ```
## Deploy more clusters
By this point you already have a sample postgres and mongodb deployed, including grafana for PG. To deploy another mongodb or postgres DB, simply run:
```
kubectl apply -f mongodb.yml
kubectl apply -f pg-cluster.yml
```
You can use these yml files as a template to play around. If you want to access the databases with mongosh or psql, you will need to forward the ports as well. Just add the commands to portfw.sh, adjust the names/ports to your settings:
```
kubectl port-forward -n mongodb svc/raphi-mongodb-svc 27017:27017 &
kubectl port-forward -n postgres svc/pg-raphi-rw 5432:5432 &
```
If you already have local WSL installation of mongodb or postgres, change the destination port (the first number), for example:
```
kubectl port-forward -n postgres svc/pg-raphi-rw 54320:5432 &
```
## Access
All pods can be directly accessed with kubectl. First get a list of your pods:
```
kubectl get pods -n postgres
kubectl get pods -n mongodb
kubectl get pods -n opensearch
```
And then login with:
```
kubectl exec -it pg-raphi-1 -n postgres -- bash
kubectl exec -it raphi-mongodb-0 -n mongodb -- bash
kubectl exec -it opensearch-cluster-nodes-0 -n opensearch -- bash
```
### Postgres
The easiest way to connect to postgres is through cnpg plugin:
```
kubectl cnpg psql pg-raphi -n postgres
```
Or use psql with the port you are forwarding to:
```
psql -h localhost -p 54320 -U postgres postgres
```

### Mongodb
With mongosh, password is in mongodb.yml if you haven't changed it yet:
```
mongosh -u raphi mongodb://localhost:27017/raphi-db
```

### Grafana
Open a webbrowser and type in: https://localhost:3000
user and pass is: admin

After login, go to "Dashboards -> New -> Import" and enter this id for a really nice PG Dashboard: 20417

### OpenSearch
Open a webbrowser and type in: https://localhost:5601
user and pass is: admin

You are prompted to set a new password then.

Tip: load some sample data after you logged in, for example flight data.


## 
