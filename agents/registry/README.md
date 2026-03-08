# In-Cluster Container Registry

Docker `registry:2` deployed in the `claude-workers` namespace for caching built devcontainer images.

## Components

| File | Description |
|------|-------------|
| `pvc.yaml` | 20Gi Longhorn PVC for image storage |
| `deployment.yaml` | `registry:2` Deployment mounting PVC at `/var/lib/registry` |
| `service.yaml` | ClusterIP service `registry` on port 5000 |

## Deploy

```bash
kubectl apply -f agents/registry/
```

## In-cluster hostname

```
registry.claude-workers.svc.cluster.local:5000
```

## Health check

```bash
# From within the cluster (e.g. a debug pod in claude-workers namespace)
curl http://registry.claude-workers.svc.cluster.local:5000/v2/
# Expected: 200 OK with body {}
```

## Notes

- Registry is insecure (HTTP only). K3s nodes must be configured to trust it via `/etc/rancher/k3s/registries.yaml` (see ticket 5.2).
- Images persist across pod restarts via the Longhorn PVC.
- Resource limits: 200m CPU / 512Mi RAM (registry is I/O bound, not CPU/memory bound).
