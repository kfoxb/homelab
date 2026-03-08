# claude-worker base image

Base container image for all Claude Code worker pods.

## What's included

- **OS**: Debian Bullseye (via `mcr.microsoft.com/devcontainers/base:bullseye`)
- **Node.js 20** (via NodeSource)
- **`@anthropic-ai/claude-code`** (latest, installed globally via npm)
- **tmux** — Claude runs inside a named tmux session for interactive access
- **git** — for cloning repos and committing work
- **gh** (GitHub CLI) — for PR and issue operations
- **jq** — for JSON parsing in scripts
- **Dotfiles** from [kfoxb/dotfiles](https://github.com/kfoxb/dotfiles), cloned to `/home/claude/dotfiles` and installed at build time
- **Non-root user**: `claude` with passwordless sudo

## Building

### One-time setup: authenticate to ghcr.io

You need a GitHub personal access token (classic or fine-grained) with `write:packages` scope.

```bash
# Create a token at https://github.com/settings/tokens
export GITHUB_TOKEN=ghp_...
echo $GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
```

This only needs to be done once per machine. Docker stores the credentials in `~/.docker/config.json`.

### Build and push

```bash
bash agents/base-image/build.sh
```

This builds with a `latest` tag and a short git-SHA tag, then pushes both to `ghcr.io/kfoxb/claude-worker`.

To override the org (e.g. if you've forked this repo under a different account):

```bash
GHCR_ORG=myorg bash agents/base-image/build.sh
```

## Verification

After building, verify the image works:

```bash
IMAGE=ghcr.io/kfoxb/claude-worker:latest

docker run --rm $IMAGE claude --version
docker run --rm $IMAGE tmux -V
docker run --rm $IMAGE git --version
docker run --rm $IMAGE gh --version
docker run --rm $IMAGE jq --version
docker run --rm $IMAGE ls /home/claude/dotfiles
```

All commands should succeed and the dotfiles directory should be present.

## Notes

- Dotfiles are installed at build time. The entrypoint re-runs the install at pod start for any updates.
- The image runs as the `claude` user by default (non-root).
- In Phase 5, this image will also be pushed to the local in-cluster registry.

---

# overlay.Dockerfile

`overlay.Dockerfile` layers Claude Code tooling on top of any project devcontainer image. It is used in Phase 5 to build project-specific images that include both the project's language runtimes and Claude's worker scripts.

## What it adds

- **`@anthropic-ai/claude-code`** (installed via npm; if Node.js is absent, Node 20 is installed first)
- **tmux, jq, curl, git** (via apt-get; skipped gracefully if not on a Debian-based image)
- **Dotfiles** from [kfoxb/dotfiles](https://github.com/kfoxb/dotfiles), installed for root
- **entrypoint.sh / status-monitor.sh** — same worker scripts as the base image
- **hooks/** — Claude Code stop hooks registered at `/root/.claude/hooks/`

## Building the overlay

```bash
# Build on top of a minimal Ubuntu image
docker build \
  -f agents/base-image/overlay.Dockerfile \
  --build-arg BASE_IMAGE=ubuntu:22.04 \
  -t claude-worker-overlay:ubuntu \
  agents/base-image/

# Build on top of the homelab devcontainer
docker build \
  -f agents/base-image/overlay.Dockerfile \
  --build-arg BASE_IMAGE=ghcr.io/kfoxb/claude-worker:latest \
  -t claude-worker-overlay:homelab \
  agents/base-image/

# Build on top of a project devcontainer (typical Phase 5 use case)
docker build \
  -f agents/base-image/overlay.Dockerfile \
  --build-arg BASE_IMAGE=<project-devcontainer-image> \
  -t registry.claude-workers.svc.cluster.local:5000/<repo-slug>:<hash> \
  agents/base-image/
```

## Overlay verification

```bash
IMAGE=claude-worker-overlay:ubuntu  # or whichever tag you built

docker run --rm --entrypoint claude $IMAGE --version
docker run --rm --entrypoint tmux $IMAGE -V
docker run --rm --entrypoint git $IMAGE --version
docker run --rm --entrypoint jq $IMAGE --version
```

## Image size

| Base image                         | Approx. overlay size |
|------------------------------------|----------------------|
| ubuntu:22.04                       | ~600 MB              |
| ghcr.io/kfoxb/claude-worker:latest | ~+50 MB (most tools already present) |

Exact sizes vary with Node.js and `@anthropic-ai/claude-code` release sizes. The overlay is idempotent: running it on top of the base image adds minimal overhead because Node.js and most tools are already installed.

## Defensive design

- If npm is already available on the base image, `npm install -g @anthropic-ai/claude-code` runs directly (fast path).
- If npm is missing, Node.js 20 is downloaded and extracted before installing Claude Code.
- `apt-get install` failures are suppressed with `|| true` so the build succeeds on non-apt or already-equipped base images.
