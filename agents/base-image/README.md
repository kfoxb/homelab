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

### Prerequisites

- Docker installed locally or on a cluster node
- GitHub Container Registry access (`docker login ghcr.io`)

```bash
# One-time login
echo $GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
```

### Build and push

```bash
bash agents/base-image/build.sh
```

This builds with a `latest` tag and a short SHA tag, then pushes both to ghcr.io.

See `build.sh` for the full command if you want to run steps manually.

## Verification

After building, verify the image works:

```bash
IMAGE=ghcr.io/<org>/claude-worker:latest

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
