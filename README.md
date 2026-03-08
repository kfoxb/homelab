# k3s-cluster

Declarative configuration for a 3-node K3s homelab cluster.

## Quick Start

```bash
# Initial cluster setup (only needed once)
./setup/setup-k3s-cluster.sh

# Install Longhorn
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  -f longhorn/values.yaml

# Set local-path as non-default
kubectl apply -f k3s-overrides/

# Access Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

## Structure

```
setup/          - Cluster bootstrap scripts
longhorn/       - Longhorn storage values
k3s-overrides/  - Overrides for K3s defaults
agents/         - Claude Code agent Jobs and CronJobs
apps/           - Application workloads
adguard/        - AdGuard Home docs (runs outside cluster on Rock64)
```

## Nodes

| Hostname | IP             | RAM  | CPU        |
|----------|----------------|------|------------|
| beelink1 | 192.168.1.200 | 16GB | Intel N100 |
| beelink2 | 192.168.1.201 | 16GB | Intel N100 |
| beelink3 | 192.168.1.202 | 16GB | Intel N100 |
