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

## Node Setup

Each K3s node must trust the registry as an insecure mirror. Run the setup script once (or again after adding/reimaging nodes — it is idempotent):

```bash
bash agents/scripts/setup-registry-nodes.sh
```

This SSHes into beelink1/2/3, writes `/etc/rancher/k3s/registries.yaml`, and restarts k3s one node at a time. Each node is confirmed Ready before moving to the next.

### What the script writes on each node

```yaml
mirrors:
  "registry.claude-workers.svc.cluster.local:5000":
    endpoint:
      - "http://registry.claude-workers.svc.cluster.local:5000"
configs:
  "registry.claude-workers.svc.cluster.local:5000":
    tls:
      insecure_skip_verify: true
```

### Verify nodes can pull from the registry

Push a test image first, then run a pod that uses it:

```bash
# Tag and push a small image into the registry (from a pod or via port-forward)
kubectl port-forward -n claude-workers svc/registry 5000:5000 &
docker pull hello-world
docker tag hello-world localhost:5000/hello-world:test
docker push localhost:5000/hello-world:test

# Confirm a pod can pull it from the in-cluster address
kubectl run registry-test \
  --image=registry.claude-workers.svc.cluster.local:5000/hello-world:test \
  --restart=Never --rm -it -n claude-workers
```

## Notes

- Registry is insecure (HTTP only). K3s nodes must be configured via the script above before pods can pull images.
- Images persist across pod restarts via the Longhorn PVC.
- Resource limits: 200m CPU / 512Mi RAM (registry is I/O bound, not CPU/memory bound).
