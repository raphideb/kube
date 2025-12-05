#!/bin/bash

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Kubernetes Cluster Setup with Operators${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Prompt for user inputs
read -p "Enter Kubernetes version (default: v1.34): " K8S_VERSION
K8S_VERSION=${K8S_VERSION:-v1.34}

read -p "Enter pod network CIDR (default: 10.244.0.0/16): " POD_CIDR
POD_CIDR=${POD_CIDR:-10.244.0.0/16}

read -p "Enter PostgreSQL storage size (default: 20Gi): " PG_STORAGE
PG_STORAGE=${PG_STORAGE:-20Gi}

read -p "Enter PostgreSQL replica count (default: 1): " PG_REPLICAS
PG_REPLICAS=${PG_REPLICAS:-1}

read -p "Enter MongoDB storage size (default: 20Gi): " MONGO_STORAGE
MONGO_STORAGE=${MONGO_STORAGE:-20Gi}

read -p "Enter MongoDB replica count (default: 1): " MONGO_REPLICAS
MONGO_REPLICAS=${MONGO_REPLICAS:-1}

read -sp "Enter MongoDB admin password: " MONGO_PASSWORD
echo ""

if [ -z "$MONGO_PASSWORD" ]; then
    echo -e "${RED}MongoDB password cannot be empty!${NC}"
    exit 1
fi

read -p "Enter local path for persistent storage (default: /opt/local-path-provisioner): " LOCAL_STORAGE_PATH
LOCAL_STORAGE_PATH=${LOCAL_STORAGE_PATH:-/opt/local-path-provisioner}

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Kubernetes Version: $K8S_VERSION"
echo "Pod Network CIDR: $POD_CIDR"
echo "PostgreSQL Storage: $PG_STORAGE (replicas: $PG_REPLICAS)"
echo "MongoDB Storage: $MONGO_STORAGE (replicas: $MONGO_REPLICAS)"
echo "Local Storage Path: $LOCAL_STORAGE_PATH"
echo ""

read -p "Continue with installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Step 1: Checking systemd configuration...${NC}"
if ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    echo "Enabling systemd in WSL..."
    sudo bash -c 'cat > /etc/wsl.conf <<EOF
[boot]
systemd=true
EOF'
    echo -e "${YELLOW}WSL needs to be restarted. Please run 'wsl.exe --shutdown' from PowerShell and restart this script.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Step 2: Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker $USER
    echo -e "${YELLOW}Docker installed. You may need to log out and back in.${NC}"
else
    echo "Docker already installed."
fi

# Ensure socat is installed
if ! command -v socat &> /dev/null; then
    sudo apt-get install -y socat
fi

# Configure Docker cgroup driver
echo ""
echo -e "${GREEN}Step 3: Configuring Docker cgroup driver...${NC}"
if ! grep -q "native.cgroupdriver=systemd" /etc/docker/daemon.json 2>/dev/null; then
    echo "Configuring Docker cgroup driver to systemd..."
    sudo mkdir -p /etc/docker
    sudo bash -c 'cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF'
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    sleep 5
    echo "Docker cgroup driver configured."
else
    echo "Docker cgroup driver already configured."
fi

echo ""
echo -e "${GREEN}Step 4: Installing cri-dockerd...${NC}"
if ! command -v cri-dockerd &> /dev/null; then
    CRI_VERSION="0.3.15"
    wget -q https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_VERSION}/cri-dockerd_${CRI_VERSION}.3-0.debian-bookworm_amd64.deb
    sudo dpkg -i cri-dockerd_${CRI_VERSION}.3-0.debian-bookworm_amd64.deb
    rm cri-dockerd_${CRI_VERSION}.3-0.debian-bookworm_amd64.deb
    sudo systemctl enable cri-docker.service
    sudo systemctl enable cri-docker.socket
    sudo systemctl start cri-docker.service
    echo "cri-dockerd installed."
else
    echo "cri-dockerd already installed."
fi

echo ""
echo -e "${GREEN}Step 5: Installing Kubernetes components...${NC}"
if ! command -v kubeadm &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg
    
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    
    echo "Installed Kubernetes version:"
    kubeadm version
    sudo systemctl enable kubelet
    echo "Kubernetes components installed and enabled for automatic startup."
else
    echo "Kubernetes components already installed."
    kubeadm version
fi

echo ""
echo -e "${GREEN}Step 6: Disabling swap...${NC}"
sudo swapoff -a
sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Create systemd service to disable swap on boot (WSL can re-enable swap on restart)
if [ ! -f /etc/systemd/system/disable-swap.service ]; then
    echo "Creating systemd service to disable swap on boot..."
    sudo bash -c 'cat > /etc/systemd/system/disable-swap.service <<EOF
[Unit]
Description=Disable swap for Kubernetes
DefaultDependencies=no
After=local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/sbin/swapoff -a
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF'
    sudo systemctl enable disable-swap.service
    echo "Systemd service created and enabled."
else
    echo "Swap disable service already exists."
fi

echo "Swap disabled."

echo ""
echo -e "${GREEN}Step 7: Initializing Kubernetes cluster...${NC}"
if [ ! -f /etc/kubernetes/admin.conf ]; then
    sudo kubeadm config images pull --cri-socket unix:///var/run/cri-dockerd.sock
    
    sudo kubeadm init \
        --pod-network-cidr=${POD_CIDR} \
        --cri-socket unix:///var/run/cri-dockerd.sock \
        --ignore-preflight-errors=NumCPU,Mem
    
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    echo "Cluster initialized."
else
    echo "Cluster already initialized."
fi

echo ""
echo -e "${GREEN}Step 8: Installing Calico CNI...${NC}"
if ! kubectl get daemonset calico-node -n calico-system &> /dev/null; then
    # Install Tigera operator
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/tigera-operator.yaml
    
    # Wait for tigera-operator to be ready
    echo "Waiting for tigera-operator to be ready..."
    kubectl wait --for=condition=available deployment/tigera-operator -n tigera-operator --timeout=120s
    
    # Create Installation with correct CIDR
    cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
    
    echo "Waiting for tigera-operator to create Calico components..."
    
    # Wait for calico-system namespace
    for i in {1..24}; do
        if kubectl get namespace calico-system &> /dev/null; then
            echo "  calico-system namespace created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for calico-system namespace${NC}"
            kubectl logs -n tigera-operator -l k8s-app=tigera-operator --tail=50
            exit 1
        fi
        sleep 5
    done
    
    # Wait for calico-node daemonset
    for i in {1..24}; do
        if kubectl get daemonset calico-node -n calico-system &> /dev/null; then
            echo "  calico-node daemonset created."
            break
        fi
        if [ $i -eq 24 ]; then
            echo -e "${RED}Timeout waiting for calico-node daemonset${NC}"
            kubectl logs -n tigera-operator -l k8s-app=tigera-operator --tail=50
            exit 1
        fi
        sleep 5
    done
    
    # Wait for pods to be ready
    echo "Waiting for Calico pods to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s
    
    echo "Calico installed and ready."
else
    echo "Calico already installed."
fi

echo ""
echo -e "${GREEN}Step 9: Removing control plane taint...${NC}"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- --overwrite=true 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master- --overwrite=true 2>/dev/null || true

echo ""
echo -e "${GREEN}Step 10: Verifying node status...${NC}"
kubectl get nodes
NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
if [ "$NODE_STATUS" == "True" ]; then
    echo -e "${GREEN}Node is Ready!${NC}"
else
    echo -e "${YELLOW}Warning: Node is not Ready yet. Waiting...${NC}"
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
fi

echo ""
echo -e "${GREEN}Step 11: Installing local-path-provisioner...${NC}"
if ! kubectl get storageclass local-path &> /dev/null; then
    # Create storage directory
    sudo mkdir -p ${LOCAL_STORAGE_PATH}
    sudo chmod 777 ${LOCAL_STORAGE_PATH}
    
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
    
    echo "Waiting for provisioner to be ready..."
    sleep 15
    if kubectl wait --for=condition=ready pod -l app=local-path-provisioner -n local-path-storage --timeout=180s 2>/dev/null; then
        echo "Local-path-provisioner is ready."
    else
        echo -e "${YELLOW}Warning: Wait timeout, checking pod status...${NC}"
        POD_STATUS=$(kubectl get pods -n local-path-storage -l app=local-path-provisioner -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [ "$POD_STATUS" == "Running" ]; then
            echo -e "${GREEN}Pod is running. Continuing...${NC}"
        else
            echo -e "${RED}Pod status: $POD_STATUS${NC}"
            echo "Check with: kubectl describe pod -n local-path-storage -l app=local-path-provisioner"
        fi
    fi
    
    # Set as default storage class
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    echo "Local-path-provisioner installed and set as default."
else
    echo "Local-path-provisioner already installed."
fi

echo ""
echo -e "${GREEN}Step 12: Installing Helm...${NC}"
if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "Helm installed."
else
    echo "Helm already installed."
fi

echo ""
echo -e "${GREEN}Step 13: Installing Metrics Server...${NC}"
if ! kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

    echo "Waiting for metrics-server deployment to be created..."
    sleep 5

    # Patch metrics-server to skip TLS verification (common for self-hosted clusters)
    kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

    echo "Waiting for metrics-server to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s

    # Wait a bit for metrics to be available
    echo "Waiting for metrics to become available..."
    sleep 10

    echo "Metrics Server installed and ready."
else
    echo "Metrics Server already installed."
fi

echo ""
echo -e "${GREEN}Step 14: Creating namespaces...${NC}"
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -
echo "Namespaces created."

echo ""
echo -e "${GREEN}Step 15: Installing CloudNativePG operator...${NC}"
if ! helm list -n postgres | grep -q cnpg-operator; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update
    helm install cnpg-operator cnpg/cloudnative-pg --namespace postgres
    
    echo "Waiting for CloudNativePG operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n postgres --timeout=180s
    echo "CloudNativePG operator installed."
    echo "Installing cnpg plugin"
    curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin
else
    echo "CloudNativePG operator already installed."
fi

echo ""
echo -e "${GREEN}Step 16: Deploying PostgreSQL cluster...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: postgres
spec:
  instances: ${PG_REPLICAS}
  monitoring:
    enablePodMonitor: false
  storage:
    size: ${PG_STORAGE}
    storageClass: local-path
EOF

echo "PostgreSQL cluster deployment initiated."

# Wait for PostgreSQL pods to be ready before creating PodMonitor
echo "Waiting for all ${PG_REPLICAS} PostgreSQL pod(s) to be created..."
for i in {1..120}; do
    POD_COUNT=$(kubectl get pods -n postgres -l cnpg.io/cluster=postgres-cluster --no-headers 2>/dev/null | wc -l)
    if [ "$POD_COUNT" -ge "${PG_REPLICAS}" ]; then
        echo "  All ${PG_REPLICAS} pod(s) detected."
        break
    fi
    sleep 2
done

echo "  Waiting for all pods to be ready (Running + Ready condition)..."
for i in {1..120}; do
    # Get count of Running pods (use || echo "0" to prevent set -e from exiting)
    READY_COUNT=$(kubectl get pods -n postgres -l cnpg.io/cluster=postgres-cluster --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [ "$READY_COUNT" -ge "${PG_REPLICAS}" ]; then
        if kubectl wait --for=condition=ready pod -l cnpg.io/cluster=postgres-cluster -n postgres --timeout=10s >/dev/null 2>&1; then
            echo "  All ${PG_REPLICAS} PostgreSQL pod(s) are ready!"
            break
        fi
    fi
    if [ $((i % 5)) -eq 0 ]; then
        echo "    $READY_COUNT of ${PG_REPLICAS} pod(s) ready..."
    fi
    sleep 2
done

# Create PodMonitor for PostgreSQL cluster AFTER pods are ready
# This prevents silent rejection by the kube-prometheus-stack admission webhook
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: postgres-cluster
  namespace: postgres
  labels:
    cnpg.io/cluster: postgres-cluster
spec:
  namespaceSelector:
    matchNames:
    - postgres
  selector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
  podMetricsEndpoints:
  - port: metrics
    path: /metrics
    interval: 30s
EOF

# Create PodMonitor for the CloudNativePG operator
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator
  namespace: postgres
  labels:
    app.kubernetes.io/name: cloudnative-pg
spec:
  namespaceSelector:
    matchNames:
    - postgres
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
  - port: metrics
EOF

echo "PodMonitor resources created (will activate when monitoring stack is installed)."
echo "Use 'kubectl get clusters -n postgres' to monitor cluster status."

echo ""
echo -e "${GREEN}Step 17: Installing MongoDB operator...${NC}"
if ! helm list -n mongodb | grep -q mongodb-operator; then
    helm repo add mongodb https://mongodb.github.io/helm-charts
    helm repo update
    helm install mongodb-operator mongodb/community-operator --namespace mongodb
    
    echo "Waiting for MongoDB operator to be ready..."
    sleep 15
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mongodb-kubernetes-operator -n mongodb --timeout=180s || true
    echo "MongoDB operator installed."
else
    echo "MongoDB operator already installed."
fi

echo ""
echo -e "${GREEN}Step 18: Creating MongoDB admin password secret...${NC}"
kubectl create secret generic mongodb-admin-password \
    --from-literal="password=${MONGO_PASSWORD}" \
    --namespace mongodb \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo -e "${GREEN}Step 19: Deploying MongoDB cluster...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: mongodb-cluster
  namespace: mongodb
spec:
  members: ${MONGO_REPLICAS}
  type: ReplicaSet
  version: "7.0.0"
  security:
    authentication:
      modes: ["SCRAM"]
  users:
    - name: admin
      db: admin
      passwordSecretRef:
        name: mongodb-admin-password
      roles:
        - name: clusterAdmin
          db: admin
        - name: userAdminAnyDatabase
          db: admin
      scramCredentialsSecretName: mongodb-admin-scram
  statefulSet:
    spec:
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: local-path
            resources:
              requests:
                storage: ${MONGO_STORAGE}
EOF

echo "MongoDB cluster deployment initiated. Use 'kubectl get mongodb -n mongodb' to monitor."

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get nodes"
echo "  kubectl get pods --all-namespaces"
echo "  kubectl top pods -A"
echo "  kubectl top nodes"
echo "  kubectl get clusters -n postgres"
echo "  kubectl get mongodb -n mongodb"
echo "  kubectl get pv"
echo "  kubectl get pvc --all-namespaces"
echo ""
echo -e "${YELLOW}Access PostgreSQL:${NC}"
echo "  kubectl exec -it postgres-cluster-1 -n postgres -- psql -U postgres"
echo ""
echo -e "${YELLOW}Access MongoDB:${NC}"
echo "  kubectl exec -it mongodb-cluster-0 -n mongodb -- mongosh -u admin -p"
echo ""
echo -e "${YELLOW}Persistent storage location:${NC}"
echo "  ${LOCAL_STORAGE_PATH}"
echo ""
echo -e "${YELLOW}Manage services:${NC}"
echo "  Start: sudo systemctl start docker cri-docker kubelet"
echo "  Stop:  sudo systemctl stop kubelet cri-docker docker"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  Run ./create_os.sh to deploy OpenSearch"
echo "  Run ./create_oracle.sh to deploy Oracle 23free"
echo ""
exit 0
