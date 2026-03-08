# K3s Homelab Cluster

## Cluster Overview

3-node K3s HA cluster running on Beelink Mini S12 Pro NUCs (Intel N100, 16GB RAM each).
All nodes are server nodes (control plane + workload) with embedded etcd for HA quorum.

### Nodes

| Hostname | IP              | Role                  |
|----------|-----------------|-----------------------|
| beelink1 | 192.168.1.200  | server (control+work) |
| beelink2 | 192.168.1.201  | server (control+work) |
| beelink3 | 192.168.1.202  | server (control+work) |

- OS: Ubuntu Server (minimal) on all nodes
- K3s version: v1.34.5+k3s1
- SSH user: fox (passwordless sudo configured)
- CPU governor: powersave (for power efficiency)
- Wifi: disabled (ethernet only via gigabit switch)

### Storage

- **Longhorn** is the default StorageClass (replicated, 2 replicas across nodes)
- **local-path** is available but not default (single-node, no replication)
- Use `longhorn` for anything where losing data matters (databases, persistent state)
- Use `local-path` for scratch/ephemeral data where replication overhead isn't worth it
- Longhorn uses iSCSI — pods can schedule on any node regardless of where replicas live
- Prerequisites installed on all nodes: open-iscsi, nfs-common

### Networking

- K3s ships with Traefik as ingress controller and ServiceLB
- ServiceLB binds to node IPs on requested ports (no virtual IP pool like MetalLB)
- All three NUCs connected via gigabit switch
- NUCs have 1Gbps ethernet (not 10GbE)

### Other Hardware

- 3x Rock64 boards (2GB RAM, ARM64) — NOT part of the cluster
  - One designated for AdGuard Home (parental controls + ad blocking)
  - Others available for standalone lightweight services
- 1x ASUS Chromebox CN60 — too old/weak for cluster, could run a single lightweight service

## Intended Workloads

- **DevPod** devcontainers (replacing GitHub Codespaces for always-on dev environments)
- **Claude Code agents** running as Jobs/CronJobs for:
  - Ticket triage and investigation
  - Background PR comment resolution
  - Automated code review
- **PostgreSQL** (single instance backed by Longhorn, not replicated at DB level)
- **Background scripts and automation**
- **Personal projects** (separate from work, but same cluster)

## Commands

```bash
# SSH into nodes
ssh fox@192.168.1.200  # beelink1
ssh fox@192.168.1.201  # beelink2
ssh fox@192.168.1.202  # beelink3

# Kubeconfig is at ~/.kube/config on fox's laptop

# Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80

# Upgrade longhorn with values from this repo
helm upgrade longhorn longhorn/longhorn -n longhorn-system -f longhorn/values.yaml

# Apply k3s overrides
kubectl apply -f k3s-overrides/
```

## Conventions

- All Kubernetes manifests go in this repo
- Helm charts use values files committed to the repo (never bare `--set` flags in production)
- Directory per concern: longhorn/, agents/, apps/, adguard/, k3s-overrides/
- README.md in each directory explaining what's there
