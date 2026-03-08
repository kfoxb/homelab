# Phase 5: Devcontainer Image Building

## Goal

Let Claude work in the same environment a human developer would use. When a project has a `.devcontainer/Dockerfile`, build it and layer Claude Code tooling on top — so Claude gets the right Node version, the right language runtimes, the right tooling.

## What Gets Built

- **In-cluster container registry** (`registry:2`) with Longhorn storage for image caching
- **K3s registries config** on all nodes to trust the local registry
- **Overlay Dockerfile** that adds Claude tooling to any base devcontainer image
- **Kaniko Job template** for in-cluster image building (no Docker daemon required)
- **`ccw build` subcommand** to trigger and monitor builds
- **Auto-detection in `ccw start`** — if `.devcontainer/Dockerfile` exists, use it

## Architecture

### Why In-Cluster Registry

Devcontainer images are large (often 2–5GB with all the language tooling). Rebuilding and pulling from ghcr.io on every task start would be slow. A local registry means:
- Build once, pull fast from any node
- No internet bandwidth for repeated pulls
- Works even if internet is down

### Registry Setup

`registry:2` deployed as a Deployment in the `claude-workers` namespace with a 20Gi Longhorn PVC. Exposed as a ClusterIP service: `registry.claude-workers.svc.cluster.local:5000`.

Each K3s node needs `/etc/rancher/k3s/registries.yaml` updated to mirror requests to the local registry and trust it as insecure:

```yaml
mirrors:
  "registry.claude-workers.svc.cluster.local:5000":
    endpoint:
      - "http://registry.claude-workers.svc.cluster.local:5000"
```

A setup script applies this to all 3 nodes via SSH and restarts k3s on each.

### Image Tagging

Images are tagged with a hash of the relevant Dockerfiles to enable caching:

```
registry.claude-workers.svc.cluster.local:5000/<repo-slug>:<dockerfile-hash>
```

The `<dockerfile-hash>` is `sha256sum .devcontainer/Dockerfile | cut -c1-12`. If `agents/base-image/overlay.Dockerfile` changes, all cached images are invalidated (use a separate hash component for the overlay version).

### Overlay Dockerfile

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Install Claude Code tooling on top of the project's devcontainer
USER root

RUN npm install -g @anthropic-ai/claude-code

RUN apt-get update && apt-get install -y \
    tmux \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install dotfiles
RUN git clone https://github.com/kfoxb/dotfiles /tmp/dotfiles \
    && cd /tmp/dotfiles && bash install.sh \
    && rm -rf /tmp/dotfiles

# Copy entrypoint and support scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY status-monitor.sh /usr/local/bin/status-monitor.sh
COPY hooks/ /root/.claude/hooks/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/status-monitor.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### Kaniko Build Process

Kaniko builds Docker images inside a Kubernetes Job without needing a Docker daemon. The Job:

1. Init container: clone the target repository to get `.devcontainer/Dockerfile`
2. Kaniko container: build `.devcontainer/Dockerfile` → `<project-image>`
3. Second Kaniko container: build `overlay.Dockerfile` with `BASE_IMAGE=<project-image>` → `<final-image>`
4. Push final image to local registry

### `ccw build` Flow

```bash
ccw build --repo https://github.com/user/my-app [--ref main]
```

1. Fetch the Dockerfile hash (clone briefly or use GitHub API)
2. Check if image already exists in registry with that hash tag
3. If cached: print image tag, done
4. If not: create Kaniko Job, stream logs, wait for completion, print image tag

### `ccw start` Auto-Detection

When `ccw start` is called:
1. Attempt to determine if the repo has `.devcontainer/Dockerfile` (by cloning to a temp dir or via GitHub API `/contents` endpoint with the PAT)
2. If yes: check for cached image; trigger build if needed
3. Set `CLAUDE_IMAGE` env var to the built image (or fall back to base image)

## Files

```
agents/
  registry/
    deployment.yaml           # registry:2 Deployment
    service.yaml              # ClusterIP service
    pvc.yaml                  # 20Gi Longhorn PVC
    README.md
  base-image/
    overlay.Dockerfile        # Adds Claude tooling to any devcontainer
  build-job-template.yaml     # Kaniko Job template (parameterized)
  scripts/
    setup-registry-nodes.sh   # SSH to each node, update registries.yaml
  cli/
    ccw                       # Updated: build subcommand, auto-detect in start
```

## Tickets

See [tickets.json](./tickets.json).

| # | Title |
|---|-------|
| 5.1 | Deploy in-cluster container registry |
| 5.2 | Configure K3s nodes for local registry |
| 5.3 | Create overlay Dockerfile |
| 5.4 | Implement Kaniko build Job template |
| 5.5 | Implement `ccw build` CLI subcommand |
| 5.6 | Integrate auto-build into `ccw start` |

## Verification

```bash
# Verify registry is up
kubectl get pods -n claude-workers -l app=registry
curl http://registry.claude-workers.svc.cluster.local:5000/v2/  # from inside cluster

# Build a project image
ccw build --repo https://github.com/user/my-app
# Expected: builds and caches image, prints tag

# Build again (should use cache)
ccw build --repo https://github.com/user/my-app
# Expected: "Using cached image: ..."

# Start a task using the devcontainer image
ccw start --repo https://github.com/user/my-app \
          --branch feat/test \
          --prompt "What Node version is installed? List the dev dependencies."
# Expected: Claude sees the project's actual Node version from devcontainer
```

## Dependencies

- Phase 1: base image (overlay builds on top of it)
- Phase 2: ccw CLI (for new subcommands)
- Longhorn must be operational (for registry PVC)
