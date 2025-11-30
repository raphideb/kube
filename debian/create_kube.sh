#!/bin/bash

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Kubernetes Cluster Setup on Debian${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Prompt for user inputs
read -p "Enter Kubernetes version (default: v1.34): " K8S_VERSION
K8S_VERSION=${K8S_VERSION:-v1.34}

# Validate Kubernetes version (must be >= 1.29 for swap support)
K8S_VERSION_NUM=$(echo $K8S_VERSION | sed 's/^v//' | cut -d'.' -f1-2)
K8S_MAJOR=$(echo $K8S_VERSION_NUM | cut -d'.' -f1)
K8S_MINOR=$(echo $K8S_VERSION_NUM | cut -d'.' -f2)

if [ "$K8S_MAJOR" -lt 1 ] || ([ "$K8S_MAJOR" -eq 1 ] && [ "$K8S_MINOR" -lt 29 ]); then
    echo -e "${RED}Error: Kubernetes version must be at least v1.29 for proper swap handling.${NC}"
    echo "You specified: $K8S_VERSION"
    exit 1
fi

read -p "Enter pod network CIDR (default: 10.244.0.0/16): " POD_CIDR
POD_CIDR=${POD_CIDR:-10.244.0.0/16}

read -p "Enter local path for persistent storage (default: /opt/local-path-provisioner): " LOCAL_STORAGE_PATH
LOCAL_STORAGE_PATH=${LOCAL_STORAGE_PATH:-/opt/local-path-provisioner}

echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "Kubernetes Version: $K8S_VERSION"
echo "Pod Network CIDR: $POD_CIDR"
echo "Local Storage Path: $LOCAL_STORAGE_PATH"
echo ""

read -p "Continue with installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Check for cgroup v2 and handle swap configuration
echo ""
echo -e "${GREEN}Checking system configuration...${NC}"
SWAP_DISABLED=false

if mount | grep -q "cgroup2 on /sys/fs/cgroup type cgroup2"; then
    echo -e "${GREEN}cgroup v2 detected - Kubernetes will be configured to prevent pods from using swap.${NC}"
    echo "Host applications can still use swap normally."
    USE_CGROUP2_SWAP=true
else
    echo -e "${YELLOW}cgroup v2 is not enabled on this system.${NC}"
    echo "To prevent Kubernetes pods from using swap, swap must be disabled entirely on the host."
    echo ""
    echo -e "${YELLOW}Note: Disabling swap is usually safe and is the standard Kubernetes configuration.${NC}"
    echo "System will use only RAM for all processes."
    echo ""
    read -p "Disable swap on the host? (y/n): " DISABLE_SWAP

    if [[ ! $DISABLE_SWAP =~ ^[Yy]$ ]]; then
        echo -e "${RED}Cannot proceed without either cgroup v2 or disabled swap.${NC}"
        echo "To enable cgroup v2, add 'systemd.unified_cgroup_hierarchy=1' to kernel parameters and reboot."
        exit 1
    fi

    echo "Disabling swap..."
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
    SWAP_DISABLED=true
    USE_CGROUP2_SWAP=false
    echo -e "${GREEN}Swap disabled on host.${NC}"
fi

echo ""
echo -e "${GREEN}Step 1: Installing Docker...${NC}"
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
echo -e "${GREEN}Step 2: Configuring Docker cgroup driver...${NC}"
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
echo -e "${GREEN}Step 3: Installing cri-dockerd...${NC}"
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
echo -e "${GREEN}Step 4: Installing Kubernetes components...${NC}"
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
echo -e "${GREEN}Step 5: Preparing kubeadm configuration...${NC}"
if [ "$USE_CGROUP2_SWAP" = true ]; then
    # cgroup v2 available: configure Kubernetes to prevent pods from using swap
    # while allowing host applications to use swap
    cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/cri-dockerd.sock
  ignorePreflightErrors:
    - NumCPU
    - Mem
    - Swap
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: NoSwap
EOF
    echo "Kubeadm configuration created with NoSwap behavior (pods cannot use swap)."
else
    # Swap is disabled on host: standard configuration
    cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/cri-dockerd.sock
  ignorePreflightErrors:
    - NumCPU
    - Mem
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_CIDR}
EOF
    echo "Kubeadm configuration created (swap disabled on host)."
fi

echo ""
echo -e "${GREEN}Step 6: Initializing Kubernetes cluster...${NC}"
if [ ! -f /etc/kubernetes/admin.conf ]; then
    sudo kubeadm config images pull --cri-socket unix:///var/run/cri-dockerd.sock

    sudo kubeadm init --config /tmp/kubeadm-config.yaml

    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "Cluster initialized."
else
    echo "Cluster already initialized."
fi

echo ""
echo -e "${GREEN}Step 7: Installing Calico CNI...${NC}"
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
echo -e "${GREEN}Step 8: Removing control plane taint...${NC}"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- --overwrite=true 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master- --overwrite=true 2>/dev/null || true

echo ""
echo -e "${GREEN}Step 9: Verifying node status...${NC}"
kubectl get nodes
NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
if [ "$NODE_STATUS" == "True" ]; then
    echo -e "${GREEN}Node is Ready!${NC}"
else
    echo -e "${YELLOW}Warning: Node is not Ready yet. Waiting...${NC}"
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
fi

echo ""
echo -e "${GREEN}Step 10: Installing local-path-provisioner...${NC}"
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
echo -e "${GREEN}Step 11: Installing Helm...${NC}"
if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "Helm installed."
else
    echo "Helm already installed."
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Kubernetes Cluster Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get nodes"
echo "  kubectl get pods --all-namespaces"
echo "  kubectl get pv"
echo "  kubectl get storageclass"
echo ""
echo -e "${YELLOW}Persistent storage location:${NC}"
echo "  ${LOCAL_STORAGE_PATH}"
echo ""
echo -e "${YELLOW}Manage services:${NC}"
echo "  Start: sudo systemctl start docker cri-docker kubelet"
echo "  Stop:  sudo systemctl stop kubelet cri-docker docker"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  Run ./create_mon.sh to deploy Grafana and Prometheus monitoring"
echo "  Run ./create_pg.sh to deploy PostgreSQL"
echo "  Run ./create_mongodb.sh to deploy MongoDB"
echo "  Run ./create_os.sh to deploy OpenSearch"
echo "  Run ./create_oracle.sh to deploy Oracle 23free"
echo ""
exit 0
