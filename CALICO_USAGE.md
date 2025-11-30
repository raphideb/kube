# Calico Advanced Usage Guide

This guide covers advanced networking and security features available with Calico in your Kubernetes cluster.

## Table of Contents

1. [Network Policies for Security Isolation](#1-network-policies-for-security-isolation)
2. [Network Observability with Flow Logs](#2-network-observability-with-flow-logs)
3. [Service Mesh-like Features](#3-service-mesh-like-features)
4. [Multi-Tenancy Isolation](#4-multi-tenancy-isolation)
5. [Rate Limiting & QoS](#5-rate-limiting--qos)
6. [Geo-blocking / IP Whitelisting](#6-geo-blocking--ip-whitelisting)
7. [Advanced Monitoring Dashboards](#7-advanced-monitoring-dashboards)
8. [Simulate Network Failures](#8-simulate-network-failures)
9. [Practical Lab Projects](#practical-lab-projects)

---

## 1. Network Policies for Security Isolation

Implement zero-trust security by controlling which pods can talk to each other.

### Example: Protect Your Databases

Only allow specific applications to access PostgreSQL:

```yaml
# postgres-access-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-restricted-access
  namespace: postgres
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: myapp-namespace
      podSelector:
        matchLabels:
          app: myapp
    ports:
    - protocol: TCP
      port: 5432
```

### Example: MongoDB Isolation

```yaml
# mongodb-access-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mongodb-restricted-access
  namespace: mongodb
spec:
  podSelector:
    matchLabels:
      app: mongodb-cluster-svc
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: myapp-namespace
      podSelector:
        matchLabels:
          app: myapp
    ports:
    - protocol: TCP
      port: 27017
```

### Example: Block Internet Access from Specific Pods

Prevent databases from making external connections:

```yaml
# database-no-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-no-egress
  namespace: mongodb
spec:
  podSelector:
    matchLabels:
      app: mongodb-cluster-svc
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}  # Only internal cluster traffic
    ports:
    - protocol: TCP
      port: 53  # Allow DNS
    - protocol: UDP
      port: 53
```

### Apply Network Policies

```bash
kubectl apply -f postgres-access-policy.yaml
kubectl apply -f mongodb-access-policy.yaml
kubectl apply -f database-no-egress.yaml

# Verify policies
kubectl get networkpolicies -A
kubectl describe networkpolicy postgres-restricted-access -n postgres
```

---

## 2. Network Observability with Flow Logs

Enable Calico's flow logging to see all network traffic and identify security issues.

### Enable Flow Logs

```bash
# Enable flow logs
kubectl patch felixconfiguration default --type merge --patch \
  '{"spec":{"flowLogsEnableNetworkSets":true,"flowLogsFileEnabled":true}}'

# View flows
kubectl logs -n calico-system -l k8s-app=calico-node --tail=100 | grep "calico-packet"
```

### Export to Prometheus

Add Calico metrics to your existing Prometheus setup:

```yaml
# calico-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: calico-felix
  namespace: calico-system
spec:
  selector:
    matchLabels:
      k8s-app: calico-node
  endpoints:
  - port: prometheus
    interval: 30s
```

Apply:
```bash
kubectl apply -f calico-servicemonitor.yaml
```

### Create Grafana Dashboards

Use Calico metrics to create dashboards showing:
- Pod-to-pod communication patterns
- Blocked connection attempts (network policy denials)
- Network traffic volume by namespace
- Top talkers (most active pods)
- Connection tracking statistics

**Example Prometheus Queries:**

```promql
# Network policy denials
sum(rate(calico_denied_packets[5m])) by (policy)

# Allowed connections
sum(rate(calico_allowed_packets[5m])) by (namespace)

# Bandwidth usage by namespace
sum(rate(calico_ipip_encap_bytes[5m])) by (namespace)

# Active connections
calico_ipset_entries{ipset_name=~".*"}
```

---

## 3. Service Mesh-like Features

### Encrypt Pod-to-Pod Traffic with WireGuard

Enable encryption for all pod communication across nodes:

```bash
# Enable WireGuard encryption
kubectl patch felixconfiguration default --type merge --patch \
  '{"spec":{"wireguardEnabled":true}}'

# Verify WireGuard is enabled
kubectl get nodes -o yaml | grep -i wireguard

# Check WireGuard interfaces on nodes
kubectl get nodes -o wide
ssh <node-ip>
sudo wg show
```

**Benefits:**
- Automatic encryption of all inter-node traffic
- No application changes required
- Minimal performance overhead
- Protection against network sniffing

---

## 4. Multi-Tenancy Isolation

Create isolated network zones for different applications or teams.

### Default Deny All Policy

Start with a deny-all policy and explicitly allow only required traffic:

```yaml
# default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### Allow Specific Application Communication

```yaml
# myapp-allowed-traffic.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: myapp-allowed
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: myapp
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow incoming traffic on app port
  - from:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 8080
  egress:
  # Allow database access
  - to:
    - namespaceSelector:
        matchLabels:
          name: postgres
    ports:
    - protocol: TCP
      port: 5432
  # Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
  # Allow external HTTPS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443
```

### Namespace Isolation

Create isolated environments for dev/staging/prod:

```yaml
# namespace-isolation.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: development
  labels:
    environment: dev
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: prod
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-production
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Only allow traffic from production namespace
  - from:
    - namespaceSelector:
        matchLabels:
          environment: prod
  egress:
  # Only allow traffic to production namespace
  - to:
    - namespaceSelector:
        matchLabels:
          environment: prod
  # Allow DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
```

---

## 5. Rate Limiting & QoS

Control bandwidth usage and connection rates per application.

### Bandwidth Rate Limiting

```yaml
# rate-limit-app.yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: rate-limit-myapp
spec:
  selector: app == "myapp"
  types:
  - Egress
  egress:
  - action: Allow
    protocol: TCP
    destination:
      ports:
      - 443
    # Limit to 100 packets per second
    rateLimit:
      packetsPerSecond: 100
```

### Apply with calicoctl

```bash
# Install calicoctl if not already installed
curl -L https://github.com/projectcalico/calico/releases/latest/download/calicoctl-linux-amd64 -o calicoctl
chmod +x calicoctl
sudo mv calicoctl /usr/local/bin/

# Configure calicoctl
export DATASTORE_TYPE=kubernetes
export KUBECONFIG=~/.kube/config

# Apply the policy
calicoctl apply -f rate-limit-app.yaml

# Verify
calicoctl get globalnetworkpolicy
```

---

## 6. Geo-blocking / IP Whitelisting

Block or allow connections from specific IP ranges.

### Define Allowed IP Ranges

```yaml
# allowed-external-ips.yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkSet
metadata:
  name: allowed-external-ips
  labels:
    type: allowed-ips
spec:
  nets:
  - 192.168.1.0/24  # Your local network
  - 10.0.0.0/8      # Internal networks
  - 172.16.0.0/12   # Private networks
```

### Whitelist External Access

```yaml
# whitelist-external-policy.yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: whitelist-external
spec:
  selector: has(expose-external)
  types:
  - Ingress
  ingress:
  - action: Allow
    source:
      selector: type == "allowed-ips"
  - action: Deny
```

### Label Pods to Apply Whitelist

```yaml
# Add label to pods that should be whitelisted
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      labels:
        app: myapp
        expose-external: "true"  # Apply whitelist
    spec:
      containers:
      - name: myapp
        image: myapp:latest
```

### Apply

```bash
calicoctl apply -f allowed-external-ips.yaml
calicoctl apply -f whitelist-external-policy.yaml
```

---

## 7. Advanced Monitoring Dashboards

### Prometheus Metrics for Grafana

Create custom dashboards using these Calico metrics:

**Network Policy Metrics:**
```promql
# Denied packets by policy
sum(rate(calico_denied_packets[5m])) by (policy)

# Allowed packets by policy
sum(rate(calico_allowed_packets[5m])) by (policy)

# Policy evaluation time
histogram_quantile(0.95, rate(calico_policy_duration_seconds_bucket[5m]))
```

**Connection Tracking:**
```promql
# Active connections
calico_ipset_entries

# Connection tracking table size
calico_conntrack_limit

# Connection tracking utilization
calico_conntrack_current / calico_conntrack_limit * 100
```

**Bandwidth Metrics:**
```promql
# Ingress bandwidth by namespace
sum(rate(container_network_receive_bytes_total[5m])) by (namespace)

# Egress bandwidth by namespace
sum(rate(container_network_transmit_bytes_total[5m])) by (namespace)

# IPIP encapsulation overhead
sum(rate(calico_ipip_encap_bytes[5m]))
```

**Top Talkers:**
```promql
# Top 10 pods by network traffic
topk(10, sum(rate(container_network_transmit_bytes_total[5m])) by (pod, namespace))
```

### Sample Grafana Dashboard JSON

Access Grafana at http://<your-host-ip>:30000 and import dashboard ID **12175** for Calico metrics, or create custom panels with the queries above.

---

## 8. Simulate Network Failures

Test application resilience by creating temporary network disruptions.

### Simulate Database Outage

```yaml
# simulate-db-outage.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: simulate-db-outage
  namespace: postgres
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
  policyTypes:
  - Ingress
  ingress: []  # Deny all - simulates complete outage
```

### Simulate Partial Network Degradation

```yaml
# simulate-degradation.yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: simulate-latency
spec:
  selector: app == "myapp"
  types:
  - Egress
  egress:
  - action: Allow
    protocol: TCP
    # Drop 10% of packets to simulate network issues
    rateLimit:
      packetsPerSecond: 10
```

### Apply and Remove

```bash
# Apply to simulate failure
kubectl apply -f simulate-db-outage.yaml

# Watch application behavior
kubectl logs -f deployment/myapp

# Remove to restore connectivity
kubectl delete -f simulate-db-outage.yaml
```

---

## Practical Lab Projects

### Project 1: Security Audit Dashboard

**Objectives:**
- Create network policies for all services
- Enable flow logs
- Build Grafana dashboard showing security metrics

**Steps:**

1. **Deploy Network Policies:**
```bash
# Create policies for each namespace
kubectl apply -f postgres-access-policy.yaml
kubectl apply -f mongodb-access-policy.yaml
kubectl apply -f monitoring-access-policy.yaml
```

2. **Enable Flow Logs:**
```bash
kubectl patch felixconfiguration default --type merge --patch \
  '{"spec":{"flowLogsEnableNetworkSets":true}}'
```

3. **Create Grafana Dashboard:**
   - Go to http://<your-host-ip>:30000
   - Create dashboard with panels for:
     - Allowed vs denied connections (pie chart)
     - Network policy violations over time (graph)
     - Traffic patterns by namespace (heatmap)
     - Top blocked sources (table)

---

### Project 2: Multi-Environment Isolation

**Objectives:**
- Create dev/staging/prod namespaces
- Implement strict network policies
- Allow only specific cross-namespace communication

**Implementation:**

```bash
# Create namespaces
kubectl create namespace development
kubectl create namespace staging
kubectl create namespace production

# Label namespaces
kubectl label namespace development environment=dev
kubectl label namespace staging environment=staging
kubectl label namespace production environment=prod

# Apply isolation policies
kubectl apply -f namespace-isolation.yaml

# Deploy test applications
kubectl run test-dev --image=nginx -n development
kubectl run test-staging --image=nginx -n staging
kubectl run test-prod --image=nginx -n production

# Verify isolation
kubectl exec -n development test-dev -- curl test-prod.production.svc.cluster.local
# Should fail - isolated environments
```

---

### Project 3: API Rate Limiting

**Objectives:**
- Rate-limit external API calls
- Prevent API quota exhaustion
- Monitor connection patterns

**Implementation:**

```yaml
# api-rate-limit.yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: external-api-rate-limit
spec:
  selector: app == "myapp"
  types:
  - Egress
  egress:
  # Rate limit external HTTPS
  - action: Allow
    protocol: TCP
    destination:
      ports:
      - 443
      notNets:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
    rateLimit:
      packetsPerSecond: 50
  # Allow unlimited internal traffic
  - action: Allow
    destination:
      nets:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
```

```bash
# Apply rate limiting
calicoctl apply -f api-rate-limit.yaml

# Monitor with Prometheus
# Query: rate(calico_dropped_packets{policy="external-api-rate-limit"}[5m])
```

---

### Project 4: Database Access Control

**Objectives:**
- Implement strict NetworkPolicies for databases
- Only allow specific apps to reach specific databases
- Log all connection attempts
- Alert on unauthorized access attempts

**Implementation:**

1. **Create Strict Policies:**

```yaml
# database-access-control.yaml
---
# PostgreSQL - only allow specific app
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-strict-access
  namespace: postgres
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: postgres-cluster
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: default
      podSelector:
        matchLabels:
          app: myapp
          database: postgres
    ports:
    - protocol: TCP
      port: 5432
---
# MongoDB - only allow specific app
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mongodb-strict-access
  namespace: mongodb
spec:
  podSelector:
    matchLabels:
      app: mongodb-cluster-svc
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: default
      podSelector:
        matchLabels:
          app: myapp
          database: mongodb
    ports:
    - protocol: TCP
      port: 27017
```

2. **Label Authorized Pods:**

```bash
# Only pods with correct labels can access databases
kubectl label pod <pod-name> database=postgres
kubectl label pod <pod-name> database=mongodb
```

3. **Monitor Access:**

Create Prometheus alerts:

```yaml
# prometheus-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: calico-network-alerts
  namespace: monitoring
spec:
  groups:
  - name: calico
    interval: 30s
    rules:
    - alert: UnauthorizedDatabaseAccess
      expr: rate(calico_denied_packets{policy=~".*database.*"}[5m]) > 0
      for: 1m
      labels:
        severity: warning
      annotations:
        summary: "Unauthorized database access attempt detected"
        description: "{{ $labels.policy }} has denied {{ $value }} packets in the last 5 minutes"
```

---

## Useful Commands

### View Network Policies

```bash
# List all network policies
kubectl get networkpolicies -A

# Describe specific policy
kubectl describe networkpolicy <policy-name> -n <namespace>

# Get Calico global policies
calicoctl get globalnetworkpolicy

# View detailed policy rules
calicoctl get globalnetworkpolicy <policy-name> -o yaml
```

### Debug Network Connectivity

```bash
# Test connectivity between pods
kubectl run test-source --image=busybox -it --rm -- wget -O- http://service-name.namespace.svc.cluster.local

# Check if traffic is being blocked
kubectl logs -n calico-system -l k8s-app=calico-node | grep -i denied

# View Calico node status
calicoctl node status
```

### Monitor Network Policies

```bash
# Watch network policy events
kubectl get events --all-namespaces --watch | grep NetworkPolicy

# View flow logs
kubectl logs -n calico-system -l k8s-app=calico-node --tail=100 -f | grep "calico-packet"
```

### Troubleshooting

```bash
# Check Calico components
kubectl get pods -n calico-system

# View Calico configuration
calicoctl get felixconfiguration default -o yaml

# Check BGP peers (if using BGP)
calicoctl node status

# Verify WireGuard encryption
kubectl get nodes -o yaml | grep wireguard
```

---

## Additional Resources

- **Calico Documentation:** https://docs.tigera.io/calico/latest/about
- **Network Policy Editor:** https://editor.cilium.io/
- **Calico GitHub:** https://github.com/projectcalico/calico
- **Network Policy Recipes:** https://github.com/ahmetb/kubernetes-network-policy-recipes

---

## Notes

- All NodePort services in your cluster:
  - Grafana: http://<your-host-ip>:30000
  - Prometheus: http://<your-host-ip>:30090
  - OpenSearch: http://<your-host-ip>:30200
  - OpenSearch Dashboard: http://<your-host-ip>:30601

- Network policies are namespace-scoped unless using GlobalNetworkPolicy
- Always test policies in a development environment first
- Keep DNS access allowed in all egress policies
- Monitor Prometheus metrics to validate policy effectiveness
