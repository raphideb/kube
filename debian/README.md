# Scripts to setup a vanilla Kubernetes cluster on Debian
## Description
These scripts are designed for **native Debian installation** and are used to setup the following:

**Core Infrastructure:**

- Helm and Docker with cri-docker
- Kubernetes cluster with persistent storage and Calico networking

**Database Operators and Deployments:**

- CloudNative-PG operator with cnpg plugin and deployment of a sample DB
- MongoDB Community operator and deployment of a sample DB
- Percona MongoDB operator and deployment of a sample DB
- Oracle operator and deployment of a sample DB

**Monitoring and Search:**

- OpenSearch operator
- Prometheus
- Grafana

**Installation Scripts:**
- `create_all.sh` - All-in-one script to install Kubernetes, PostgreSQL, and MongoDB
- `create_kube.sh` - Install only Kubernetes cluster infrastructure
- `create_pg.sh` - Install PostgreSQL operator and deploy cluster with Grafana support
- `create_mongodb.sh` - Install MongoDB Community operator and deploy cluster with Grafana support
- `create_percona_mongodb.sh` - Install Percona MongoDB operator and deploy cluster with Grafana support
- `create_mon.sh` - Install Prometheus & Grafana monitoring
- `create_oracle.sh` - Deploy Oracle 23c Free Edition with Grafana support
- `create_os.sh` - Install OpenSearch operator

**YAML files for deploying additional clusters:**
- `pg-cluster.yml` - PostgreSQL cluster with Grafana support
- `mongodb.yml` - MongoDB Community cluster
- `percona_mongodb.yml` - Percona MongoDB cluster
- `opensearch.yml` - OpenSearch cluster with dashboard

**Important**

When everything is running, this setup uses over 16GB of memory.

## Swap Handling

**Note on Swap:**

If swap is configured on the host, it will remain enabled for the host but disabled for Kubernetes pods when cgroup v2 is available. Otherwise, swap will be disabled on the host entirely. Requires Kubernetes v1.29 or higher.

## Installation
This assumes that you have a working Debian installation and that you have downloaded all files into a directory. Everything can be executed as a normal user, sudo will be used where needed.

If any packages (curl, wget) are missing that are not covered by the install script, install them manually.

### Option 1: Modular Installation (Recommended)

**Recommended Order:**

```bash
./create_kube.sh    # 1. Setup Kubernetes
./create_mon.sh     # 2. Install Prometheus & Grafana (optional but recommended)
./create_pg.sh      # 3. Deploy PostgreSQL (auto-configures monitoring if available)
./create_mongodb.sh         # 4a. Deploy MongoDB Community (auto-configures monitoring if available)
./create_percona_mongodb.sh # 4b. Deploy Percona MongoDB (alternative to 4a)
./create_oracle.sh          # 5. Deploy Oracle (auto-configures monitoring if available)
./create_os.sh              # 6. Install OpenSearch operator
```

**Note:** Scripts after create_kube.sh work in any order. Each database script auto-configures its own monitoring if the monitoring stack is installed.

### Option 2: All-in-One Installation
If you want to install everything at once (Kubernetes + PostgreSQL + MongoDB):
   ```
   ./create_all.sh
   ```

### Troubleshooting Installation
You might (probably will) run into problems that you need to figure out - best way to do that is to copy/paste the error into an AI prompt like claude or perplexity. If for some reason you need to start from scratch, you can uninstall everything (except docker and helm) with this script:
   ```
   ./del_kube.sh
   ```
   And then run the installation again.

### Additional Components

**Install OpenSearch operator (optional)**

```
./create_os.sh
```

**Deploy OpenSearch cluster (optional)**

```
kubectl apply -f opensearch.yml
```

**Deploy Oracle (optional)**

```
./create_oracle.sh
```

If you want to delete everything from Oracle, run:

```
./del_oracle.sh
```

**Delete Percona MongoDB deployment**

```
./del_percona.sh
```

**Service Access**

Grafana and Prometheus are automatically exposed as NodePort services and permanently accessible at:
- Grafana: http://your-host-ip:30000
- Prometheus: http://your-host-ip:30090

For MongoDB and PostgreSQL, you need to forward the ports in a second window:

```
./portfw.sh
```

You *could* also add the ports for the oracle databases but they are randomly assigned during creation. I prefer accessing them through kubectl.

### Start Kubernetes

**Automatic Startup:**

After installation, Kubernetes services (docker, cri-docker, kubelet) are enabled to start automatically on system boot. Your cluster will be ready after a reboot without manual intervention.

**Manual Startup:**

If you need to manually start Kubernetes (e.g., after stopping services), you can use:
```
./start_kube.sh
```

This script will start all required Kubernetes services.

**Manage Services:**

```bash
# Start services
sudo systemctl start docker cri-docker kubelet

# Stop services
sudo systemctl stop kubelet cri-docker docker
```

## Deploy more clusters
If you ran `create_all.sh` or the individual database deployment scripts (`create_pg.sh` and `create_mongodb.sh`), you already have sample PostgreSQL and MongoDB clusters deployed. To deploy additional database clusters, simply run:

**MongoDB Community Edition:**

```
kubectl apply -f mongodb.yml
```

**Percona MongoDB:**

```
kubectl apply -f percona_mongodb.yml
```

**PostgreSQL:**

```
kubectl apply -f pg-cluster.yml
```

You can use these yml files as a template to play around. If you want to access the databases with mongosh or psql, you will need to forward the ports as well. Just add the commands to portfw.sh, adjust the names/ports to your settings:
```
kubectl port-forward -n mongodb svc/mongodb-cluster-svc 27017:27017 &
kubectl port-forward -n percona-mongodb svc/percona-mongodb-rs0 27017:27017 &
kubectl port-forward -n postgres svc/postgres-cluster-rw 5432:5432 &
```
If you already have a local installation of mongodb or postgres, change the destination port (the first number), for example:
```
kubectl port-forward -n postgres svc/postgres-cluster-rw 54320:5432 &
```
### Deploy more oracle databases
For oracle, additional steps are needed to setup the credentials and proper labeling for grafana, which is why a bash script is more suitable. Basic usage is:
```
./deploy-oracle.sh <db-name> <sid> <password>
```
However the sid has to be FREE for the free edition. Example:
```
./deploy-oracle.sh myoracledb FREE MySecret_123
```

## Access
All pods can be directly accessed with kubectl. First get a list of your pods:
```
kubectl get pods -n postgres
kubectl get pods -n mongodb
kubectl get pods -n percona-mongodb
kubectl get pods -n opensearch
kubectl get pods -n oracle
```
And then login with:
```
kubectl exec -it postgres-cluster-1 -n postgres -- bash
kubectl exec -it mongodb-cluster-0 -n mongodb -- bash
kubectl exec -it myoracledb-z9e4b -n oracle -- sqlplus sys/MySecret_123@FREE as sysdba
```
### Postgres
The easiest way to connect to postgres is through cnpg plugin:
```
kubectl cnpg psql postgres-cluster -n postgres
```
Or use psql with the port you are forwarding to:
```
psql -h localhost -p 54320 -U postgres postgres
```

### MongoDB (Community Edition)

With mongosh, password is in mongodb.yml if you haven't changed it yet:
```
mongosh -u admin mongodb://localhost:27017/admin
```

### MongoDB (Percona)

With mongosh, password is in percona_mongodb.yml if you haven't changed it yet:
```
kubectl exec -it percona-mongodb-rs0-0 -n percona-mongodb -- mongosh -u userAdmin -p
```

Or with port-forwarding:
```
mongosh -u userAdmin mongodb://localhost:27017/admin
```

### Oracle
The easiest way to connect to oracle is to use the script "orasql" in this repo, if the database was deployed with "deploy-oracle.sh":
```
./orasql
Usage: orasql <database-name> [namespace]

Available databases:
oracle23    Healthy   FREE
myoracledb  Healthy   FREE
```
Example:
```
./orasql myoracledb
```

Alternatively, you can list the available databases, get the corresponding pod and login with password on the commandline:
```
kubectl get singleinstancedatabase -n oracle
kubectl get pods -n oracle -l app=myoracledb -o jsonpath='{.items[0].metadata.name}'
kubectl exec -it myoracledb-z9e4b -n oracle -- sqlplus sys/MySecret_12345@FREE as sysdba
```

### Grafana
Open a webbrowser and navigate to: http://your-host-ip:30000
user and pass is: admin

After login, go to "Dashboards -> New -> Import" and enter this id for a really nice PG Dashboard: 20417

### OpenSearch
After deploying the OpenSearch cluster, access the dashboard at: http://your-host-ip:30601
user and pass is: admin

You are prompted to set a new password then.

Tip: load some sample data after you logged in, for example flight data.

Note: OpenSearch cluster needs to be deployed first with NodePort services (see create_os.sh for configuration).

## Dashboards
### OpenSearch
<img width="3839" height="2159" alt="opensearch" src="https://github.com/user-attachments/assets/a4a3b640-1a94-4f0b-b65b-656ad584448e" />

### Grafana
#### PostgreSQL
Name: CloudNativePG
Dashboard ID: 20417

<img width="3839" height="2159" alt="grafana" src="https://github.com/user-attachments/assets/8492632b-240e-47bb-afee-df10d5bce5e8" />

#### MongoDB
Name: MongoDB - Percona Exporter  

I couldn't make any of the dashboards available on grafana work. Import this custom dashboard into grafana from the repo:  
```
MongoDB_Percona_Grafana.json
```
![mongodb_grafana](https://github.com/user-attachments/assets/b2082d58-6e2c-41d2-9f75-f830e09fb5c5)

#### Oracle
Name: OracleDB Monitoring - performance and table space stats  
Original dashboard ID: 13555

The original Oracle dashboard lets you select databases only by host ip. I modified it to be able to select by database name. Import this file into grafana from the repo:
```
OracleDB_Grafana.json
```
![oracle_grafana](https://github.com/user-attachments/assets/6e2a3b2d-1267-4a55-bb8a-8bd96483b1e6)

## Troubleshooting
### prometheus node exporter
If the node export pod keeps crashing, check the log files:
```
$ kubectl get pods -n monitoring |grep node-exporter
kube-prometheus-stack-prometheus-node-exporter-xbzrm        0/1     CrashLoopBackOff   24 (51s ago)   29h
$ kubectl describe pods -n monitoring kube-prometheus-stack-prometheus-node-exporter-xbzrm
```
If you see lines like this one:
```
Warning  Failed          39s (x2 over 80s)    kubelet  Error: failed to start container "node-exporter": Error response from daemon: path / is mounted on / but it is not a shared or slave mount
```
Apply the following patch:
```
kubectl patch daemonset kube-prometheus-stack-prometheus-node-exporter -n monitoring --type=json -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/volumeMounts/2/mountPropagation"}]'
```
This should fix the issue and the pod should be running.

### grafana
My grafana pod crashed after a while and kubectl describe show this message: 
```
Warning  BackOff  2m36s (x532 over 117m)  kubelet  Back-off restarting failed container init-chown-data in pod kube-prometheus-stack-grafana
```
If this happens, chmod the PV directories (they are always 777):
```
sudo chmod -R 777 /opt/local-path-provisioner/pvc-*
```
You might need to delete the pod afterwards, a new one will automatically be created:
```
kubectl delete pod -n monitoring kube-prometheus-stack-grafana-845f8c6c46-jqn6k
```
