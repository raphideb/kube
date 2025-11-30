#!/bin/bash
echo "Starting Kubernetes cluster..."
sudo systemctl start docker
sleep 5
sudo systemctl start cri-docker
sleep 5
sudo systemctl start kubelet
echo "Waiting for cluster to be ready..."
sleep 10
kubectl get nodes
echo "Kubernetes cluster started."

