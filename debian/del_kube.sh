#!/bin/bash

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}========================================${NC}"
echo -e "${RED}Kubernetes Cluster Uninstall${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}This will remove all components installed by create_kube.sh and create_all.sh:${NC}"
echo "  - Kubernetes (kubeadm, kubectl, kubelet)"
echo "  - cnpg plugin"
echo "  - cri-dockerd"
echo "  - All operators and database clusters"
echo ""
echo -e "${YELLOW}Docker and Helm will be preserved.${NC}"
echo ""
echo -e "${RED}WARNING: This will delete all Kubernetes data including:${NC}"
echo "  - All pods, deployments, and services"
echo "  - All persistent volumes and data (including /opt/local-path-provisioner)"
echo "  - All Kubernetes configuration"
echo ""

read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
if [[ ! $CONFIRM == "yes" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Step 1: Resetting kubeadm...${NC}"
if [ -f /etc/kubernetes/admin.conf ]; then
    sudo kubeadm reset --cri-socket unix:///var/run/cri-dockerd.sock --force
    echo "Kubeadm reset completed."
else
    echo "No kubeadm configuration found, skipping reset."
fi

echo ""
echo -e "${GREEN}Step 2: Removing cnpg plugin...${NC}"
if [ -f /usr/local/bin/kubectl-cnpg ]; then
    sudo rm -f /usr/local/bin/kubectl-cnpg
    echo "cnpg plugin removed."
else
    echo "cnpg plugin not found, skipping."
fi

echo ""
echo -e "${GREEN}Step 3: Removing cri-dockerd...${NC}"
if command -v cri-dockerd &> /dev/null; then
    sudo systemctl stop cri-docker.service 2>/dev/null || true
    sudo systemctl stop cri-docker.socket 2>/dev/null || true
    sudo systemctl disable cri-docker.service 2>/dev/null || true
    sudo systemctl disable cri-docker.socket 2>/dev/null || true
    sudo apt-get purge -y cri-dockerd 2>/dev/null || true
    sudo rm -f /usr/bin/cri-dockerd
    sudo rm -f /lib/systemd/system/cri-docker.service
    sudo rm -f /lib/systemd/system/cri-docker.socket
    sudo systemctl daemon-reload
    echo "cri-dockerd removed."
else
    echo "cri-dockerd not found, skipping."
fi

echo ""
echo -e "${GREEN}Step 4: Removing Kubernetes packages...${NC}"
sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni kube* 2>/dev/null || true
sudo apt-get autoremove -y
echo "Kubernetes packages removed."

echo ""
echo -e "${GREEN}Step 5: Removing Kubernetes directories...${NC}"
# Find and unmount all kubelet-related mounts
if mountpoint -q /var/lib/kubelet 2>/dev/null || mount | grep -q '/var/lib/kubelet'; then
    echo "Found mounted volumes in /var/lib/kubelet, unmounting..."
    
    # Unmount all volumes in reverse order (deepest first)
    mount | grep '/var/lib/kubelet' | awk '{print $3}' | sort -r | while read mount_point; do
        echo "  Unmounting: $mount_point"
        sudo umount "$mount_point" 2>/dev/null || sudo umount -l "$mount_point" 2>/dev/null || true
    done
    
    # Final unmount of /var/lib/kubelet itself if it's a mount point
    if mountpoint -q /var/lib/kubelet 2>/dev/null; then
        sudo umount /var/lib/kubelet 2>/dev/null || sudo umount -l /var/lib/kubelet 2>/dev/null || true
    fi
    
    echo "Volumes unmounted."
else
    echo "No mounted volumes found in /var/lib/kubelet."
fi

rm -rf ~/.kube
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/kubelet
sudo rm -rf /var/lib/etcd
sudo rm -rf /etc/cni
sudo rm -rf /opt/cni
sudo rm -rf /var/lib/cni
sudo rm -rf /run/flannel
sudo rm -rf /etc/kube-flannel
sudo rm -rf /run/calico
sudo rm -rf /var/run/kubernetes
sudo rm -rf /etc/systemd/system/kubelet.service.d
sudo rm -rf /opt/local-path-provisioner
sudo rm -f /tmp/kubeadm-config.yaml
echo "Kubernetes directories removed."

echo ""
echo -e "${GREEN}Step 6: Removing Kubernetes repository...${NC}"
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "Kubernetes repository removed."

echo ""
echo -e "${GREEN}Step 7: Cleaning up iptables rules...${NC}"
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t raw -F
sudo iptables -t raw -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
echo "iptables rules cleaned."

echo ""
echo -e "${GREEN}Step 8: Cleaning up network interfaces...${NC}"
# Remove CNI network interfaces
for iface in $(ip link show | grep -E 'cali|flannel|cni|veth' | awk -F: '{print $2}' | tr -d ' '); do
    sudo ip link delete $iface 2>/dev/null || true
done
echo "Network interfaces cleaned."

echo ""
echo -e "${GREEN}Step 9: Cleaning up routing table entries...${NC}"
# Remove blackhole and unreachable routes created by Kubernetes/CNI
BLACKHOLE_ROUTES=$(ip route show type blackhole 2>/dev/null || true)
UNREACHABLE_ROUTES=$(ip route show type unreachable 2>/dev/null || true)

if [ -n "$BLACKHOLE_ROUTES" ] || [ -n "$UNREACHABLE_ROUTES" ]; then
    echo "Found problematic routes, removing..."

    if [ -n "$BLACKHOLE_ROUTES" ]; then
        echo "  Removing blackhole routes:"
        while IFS= read -r route; do
            if [ -n "$route" ]; then
                echo "    - $route"
                sudo ip route del $route 2>/dev/null || true
            fi
        done <<< "$BLACKHOLE_ROUTES"
    fi

    if [ -n "$UNREACHABLE_ROUTES" ]; then
        echo "  Removing unreachable routes:"
        while IFS= read -r route; do
            if [ -n "$route" ]; then
                echo "    - $route"
                sudo ip route del $route 2>/dev/null || true
            fi
        done <<< "$UNREACHABLE_ROUTES"
    fi

    echo "Routing table cleaned."
else
    echo "No problematic routes found."
fi

echo ""
echo -e "${GREEN}Step 10: Re-enabling swap if it was disabled...${NC}"
# Check if swap was commented out in fstab
if grep -q '^#.*swap' /etc/fstab 2>/dev/null; then
    echo "Swap entries found commented out in /etc/fstab."
    read -p "Re-enable swap? (y/n): " REENABLE_SWAP
    if [[ $REENABLE_SWAP =~ ^[Yy]$ ]]; then
        sudo sed -i '/swap/ s/^#//' /etc/fstab
        sudo swapon -a 2>/dev/null || true
        echo "Swap re-enabled."
    else
        echo "Swap not re-enabled."
    fi
else
    sudo swapon -a 2>/dev/null || true
    echo "Swap activated (if configured)."
fi

echo ""
echo -e "${GREEN}Step 11: Restarting Docker...${NC}"
sudo systemctl restart docker
echo "Docker restarted."

echo ""
echo -e "${GREEN}Step 12: Verifying cleanup...${NC}"
echo ""
echo "Remaining Kubernetes processes:"
ps aux | grep -E 'kube|etcd' | grep -v grep || echo "  None found."
echo ""
echo "Remaining Kubernetes directories:"
sudo find /etc /var/lib /var/run /opt -name '*kube*' -o -name '*etcd*' -o -name '*cni*' 2>/dev/null || echo "  None found."
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Kubernetes Uninstall Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}All Kubernetes components have been removed.${NC}"
echo ""
echo -e "${YELLOW}Preserved components:${NC}"
echo "  - Docker: $(docker --version 2>/dev/null || echo 'Not found')"
echo "  - Helm: $(helm version --short 2>/dev/null || echo 'Not found')"
echo ""
echo -e "${YELLOW}To reinstall Kubernetes, run ./create_kube.sh or ./create_all.sh again.${NC}"
echo ""
exit 0
