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
