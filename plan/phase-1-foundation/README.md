# Phase 1: Foundation

## Goal

Get a single Claude Code agent running in a Kubernetes pod. By the end of this phase you can manually launch a pod, `kubectl exec` into it, and watch Claude work in tmux on a real repository.

No CLI, no queue, no automation — just the raw infrastructure that everything else builds on.

## What Gets Built

- `claude-workers` Kubernetes namespace
- Secrets for API key and GitHub token
- Base container image with Claude Code, tmux, git, gh, and dotfiles
- Entrypoint script: clone repo → checkout branch → start Claude in tmux → keep-alive
- Pod manifest template (manually launched via envsubst + kubectl apply)
- RBAC so pods can self-update their own labels (needed for status tracking later)

## Files to Create

```
agents/
  namespace.yaml              # claude-workers namespace
  secrets.yaml.example        # Template for ANTHROPIC_API_KEY, GITHUB_TOKEN (gitignored actual secret)
  pod-template.yaml           # Parameterized pod manifest
  rbac.yaml                   # ServiceAccount + Role + RoleBinding
  base-image/
    Dockerfile                # Base image definition
    entrypoint.sh             # Pod startup logic
    build.sh                  # Build and push to local registry (manual for now)
    README.md
```

## Architecture

### Container Image

Base: `mcr.microsoft.com/devcontainers/base:bullseye` (matches the homelab devcontainer).

Installs:
- Node.js 20 + `@anthropic-ai/claude-code` npm package
- tmux, git, GitHub CLI (`gh`)
- jq, curl
- Dotfiles from `github.com/kfoxb/dotfiles` (run at build time for base; also re-run at pod start for fresh config)

Non-root user: `claude` with sudo.

### Entrypoint Flow

1. Configure git credential store from `GITHUB_TOKEN` env var
2. Clone `$REPO_URL` into `/workspace/`
3. Checkout `$GIT_BRANCH`; create it from default branch if it doesn't exist
4. Write initial `CLAUDE.md` context if `$CLAUDE_PROMPT_FILE` is provided
5. Start tmux session named `claude` running:
   `claude --dangerously-skip-permissions --output-format stream-json | tee /workspace/.claude-output.log`
6. Background loop: monitor tmux session, write `/tmp/claude-done` when Claude exits, update pod label `status=done` or `status=error`
7. Keep container alive with `tail -f /dev/null` (never exit — pod stays up for human interaction)

### Pod Labels

```yaml
labels:
  app: claude-worker
  task: $TASK_NAME        # generated: timestamp-shortsha
  repo: $REPO_SLUG        # org-repo (URL-safe)
  branch: $GIT_BRANCH
  ticket: $LINEAR_TICKET  # "none" if not provided
  status: running         # running | done | error | rate-limited | queued
```

### Resources

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi
```

### Storage

`emptyDir` for the workspace — state is in git. No Longhorn needed for pods.

### Registry

For Phase 1, build the image manually on a node and push to ghcr.io or the local registry (Phase 5 sets up the local registry properly). The `build.sh` script documents how.

## Tickets

See [tickets.json](./tickets.json) for structured Linear-importable tickets.

| # | Title |
|---|-------|
| 1.1 | Create claude-workers namespace and secrets manifest |
| 1.2 | Build claude-worker base Dockerfile |
| 1.3 | Write pod entrypoint script |
| 1.4 | Create pod manifest template |
| 1.5 | Build and push base image (manual) |
| 1.6 | Create RBAC for pod self-labeling |

## Verification

After completing all tickets:

```bash
# Apply base resources
kubectl apply -f agents/namespace.yaml
kubectl apply -f agents/rbac.yaml
kubectl apply -f agents/secrets.yaml  # your actual secret

# Launch a task manually
export TASK_NAME=test-$(date +%s)
export REPO_URL=https://github.com/kfoxb/some-repo
export GIT_BRANCH=feat/test-agent
export CLAUDE_PROMPT="List all the files in the repo and write a brief summary of what each one does."
export LINEAR_TICKET=none
envsubst < agents/pod-template.yaml | kubectl apply -f -

# Observe
kubectl -n claude-workers get pods
kubectl -n claude-workers exec -it $TASK_NAME -- tmux attach -t claude

# Cleanup
kubectl -n claude-workers delete pod $TASK_NAME
```

Expected result: Claude starts, lists files, writes a summary, tmux session stays alive after it finishes.

## Dependencies

None — this is the foundation phase.
