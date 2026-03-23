# Claude Code Agents

Kubernetes infrastructure for running Claude Code agents autonomously on the homelab cluster.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Setup Guide](#setup-guide)
5. [CLI Reference](#cli-reference)
6. [Workflow Guide](#workflow-guide)
7. [Configuration](#configuration)
8. [Troubleshooting](#troubleshooting)
9. [Resource Planning](#resource-planning)

---

## Overview

This system lets you delegate software engineering tasks to Claude Code agents running as Kubernetes pods. You describe a task in plain English, and a pod spins up, clones the repo, and runs Claude Code autonomously inside a tmux session. You can watch progress live, send follow-up messages, and review the results when Claude is done.

**What this replaces:** manually running `claude` on your laptop for long-running tasks. Instead, tasks run on the cluster 24/7 — you kick one off in seconds, it runs in the background, and you check back when ready.

**Key capabilities:**

- Start tasks with `ccw start` — pods are queued and scheduled automatically
- Attach to Claude's live tmux session with `ccw ssh`
- Send follow-up messages mid-task with `ccw follow-up`
- Fetch Linear ticket context automatically with `--ticket`
- Build project-specific devcontainer images for language-native environments
- Live dashboard with `ccw dashboard`
- Nightly auto-cleanup of stale pods

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Your laptop                                                         │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  ccw CLI  (agents/cli/ccw)                                  │    │
│  │  kubectl wrapper — creates pods, streams logs, attaches     │    │
│  └──────────────────────────────┬──────────────────────────────┘    │
└─────────────────────────────────│────────────────────────────────────┘
                                  │ kubectl
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes cluster  (namespace: claude-workers)                     │
│                                                                      │
│  ┌──────────────┐    ┌───────────────────────────────────────────┐  │
│  │  Scheduler   │    │  Worker Pods (one per task)               │  │
│  │  Deployment  │───▶│                                           │  │
│  │              │    │  entrypoint.sh                            │  │
│  │  Reads       │    │    └── clones repo                        │  │
│  │  worker-     │    │    └── runs claude in tmux                │  │
│  │  config CM   │    │    └── monitors status label              │  │
│  │              │    │    └── runs on-complete hook              │  │
│  │  Labels pods │    │                                           │  │
│  │  queued/     │    │  Status tracked via pod labels:           │  │
│  │  running/    │    │    status=queued|running|done|error|      │  │
│  │  rate-limited│    │           stopped|rate-limited            │  │
│  └──────────────┘    └───────────────────────────────────────────┘  │
│                                                                      │
│  ┌──────────────────────┐    ┌──────────────────────────────────┐   │
│  │  In-cluster Registry │    │  Cleanup CronJob                 │   │
│  │  registry:2          │    │  Runs 3am daily                  │   │
│  │  ClusterIP :5000     │    │  Deletes pods older than TTL     │   │
│  │  Longhorn 20Gi PVC   │    │  (default 48h) in terminal state │   │
│  └──────────────────────┘    └──────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `ccw` CLI | `agents/cli/ccw` | Main user interface — wraps kubectl |
| Pod template | `agents/pod-template.yaml` | Template for worker pods |
| Scheduler | `agents/scheduler/` | Enforces `maxConcurrent` concurrency limit |
| Base image | `agents/base-image/` | Docker image with Claude Code, tmux, git, gh |
| In-cluster registry | `agents/registry/` | Caches built devcontainer images |
| Build job template | `agents/build-job-template.yaml` | Kaniko-based image build jobs |
| Cleanup CronJob | `agents/cleanup-cronjob.yaml` | Nightly stale pod removal |
| Config | `agents/worker-config.yaml` | Concurrency and TTL settings |
| Secrets | `agents/secrets.yaml` | API keys (gitignored) |

### Pod lifecycle

```
created → queued → running → done
                           ↘ error
                           ↘ stopped  (manual ccw stop)
                           ↘ rate-limited → (scheduler retries after cooldown)
```

The scheduler Deployment watches all worker pods and promotes queued pods to running when a slot is available. It also detects rate-limited pods and re-queues them after the configured cooldown.

### Image selection

When starting a task, `ccw start` auto-detects which container image to use:

1. If `--image` is passed explicitly, that image is used.
2. If the repo has a `.devcontainer/Dockerfile`, the in-cluster registry is checked for a cached image. If found, it's used; if not, you're prompted to build one.
3. Otherwise, the base `ghcr.io/kfoxb/claude-worker:latest` image is used.

---

## Prerequisites

Before applying any manifests, ensure the following are in place:

### Cluster

- K3s cluster running (see `setup/`)
- **Longhorn** installed as default StorageClass (required by the registry PVC)
- `kubectl` configured on your laptop pointing to the cluster
- `envsubst` installed (`apt install gettext-base` or `brew install gettext`)
- `jq` installed

### Secrets

You need the following credentials:

- **`CLAUDE_CREDENTIALS`** — your Claude Pro/Max subscription credentials. Get this by running `cat ~/.claude/.credentials.json` on your laptop after logging in with `claude login`. The entire JSON object goes in the secret.
- **`GITHUB_TOKEN`** — GitHub PAT with `repo` read/write scope (for cloning and PRs)

Optionally, for Linear integration:

- **`LINEAR_API_KEY`** — from Linear workspace settings → API → Personal API keys

### Base image

The worker base image must be publicly accessible (or pulled into the cluster). It is published at `ghcr.io/kfoxb/claude-worker:latest`. To rebuild it yourself:

```bash
# Requires Docker and GITHUB_TOKEN with write:packages scope
bash agents/base-image/build.sh
```

---

## Setup Guide

Follow these steps in order to go from zero to a working agent.

### Step 1: Create the namespace

```bash
kubectl apply -f agents/namespace.yaml
```

### Step 2: Apply RBAC

```bash
kubectl apply -f agents/rbac.yaml
```

### Step 3: Apply secrets

Copy the example and fill in your keys:

```bash
cp agents/secrets.yaml.example agents/secrets.yaml
# Edit agents/secrets.yaml:
#   CLAUDE_CREDENTIALS: paste the output of: cat ~/.claude/.credentials.json
#   GITHUB_TOKEN:       your GitHub PAT
kubectl apply -f agents/secrets.yaml
```

`agents/secrets.yaml` is gitignored and will never be committed.

**Optional:** add `LINEAR_API_KEY` to the secret if you want Linear ticket context in prompts.

### Step 4: Apply worker config

```bash
kubectl apply -f agents/worker-config.yaml
```

### Step 5: Deploy the scheduler

```bash
kubectl apply -f agents/scheduler/deployment.yaml
```

Verify it's running:

```bash
kubectl get pods -n claude-workers -l app=claude-scheduler
```

### Step 6: Deploy the in-cluster registry

```bash
kubectl apply -f agents/registry/
```

This deploys the registry Deployment, ClusterIP Service, and a 20Gi Longhorn PVC. Wait for the pod to be ready:

```bash
kubectl get pods -n claude-workers -l app=registry
```

### Step 7: Configure nodes to trust the registry

Each K3s node must be configured to pull from the in-cluster registry over HTTP. Run the setup script once:

```bash
bash agents/scripts/setup-registry-nodes.sh
```

This SSHes into all three nodes, writes `/etc/rancher/k3s/registries.yaml`, and restarts K3s one node at a time — waiting for each node to return to Ready before moving to the next. It is idempotent and safe to re-run.

### Step 8: Apply the cleanup CronJob

```bash
kubectl apply -f agents/cleanup-cronjob.yaml
```

This schedules nightly cleanup of stale pods at 3am.

### Step 9: Install the CLI

**Option A: Run from the repo (development)**

```bash
# Add to your shell (or run directly)
export PATH="$PATH:/workspaces/homelab/agents/cli"
ccw --help
```

**Option B: Install via dotfiles**

If you use `kfoxb/dotfiles`, `ccw` is included at `bin/ccw` and added to PATH automatically. Set the homelab directory:

```bash
# In ~/.zshrc or ~/.bashrc
export CCW_HOMELAB_DIR=~/homelab
```

**Option C: Manual install**

```bash
bash agents/cli/install.sh
```

### Step 10: Verify

```bash
ccw list   # should show "No worker pods found."
ccw queue  # should show running: 0 / queued: 0 / rate-limited: 0
```

---

## CLI Reference

All subcommands support `--help` for detailed options.

```
ccw <subcommand> [options]
```

---

### `ccw build`

Build a devcontainer image for a repository and cache it in the in-cluster registry.

```
ccw build --repo <url> [--ref <branch/tag>] [--no-cache]
```

| Option | Description |
|--------|-------------|
| `--repo <url>` | Git repository URL (required) |
| `--ref <branch/tag>` | Branch or tag to build from (default: `main`) |
| `--no-cache` | Force rebuild even if image is already cached |

The image is named `registry.claude-workers.svc.cluster.local:5000/<repo-slug>:<dockerfile-hash>`. The tag is a 12-character hash of the `.devcontainer/Dockerfile` content — if the Dockerfile hasn't changed, the image won't be rebuilt.

**Examples:**

```bash
# Build the devcontainer for a repo on main
ccw build --repo https://github.com/myorg/myapp

# Build from a specific branch
ccw build --repo https://github.com/myorg/myapp --ref feat/new-runtime

# Force rebuild regardless of cache
ccw build --repo https://github.com/myorg/myapp --no-cache
```

---

### `ccw start`

Start a new Claude Code worker task.

```
ccw start --repo <url> --branch <name> --prompt <text> [options]
```

| Option | Description |
|--------|-------------|
| `--repo <url>` | Git repository URL (required) |
| `--branch <name>` | Branch to work on — created if it doesn't exist (required) |
| `--prompt <text>` | Initial prompt for Claude (required) |
| `--ticket <id>` | Linear ticket ID — fetches title, description, comments and prepends them to the prompt |
| `--image <image>` | Override container image; skips auto-detection |
| `--auto-build` | Build the devcontainer image without prompting if not cached |

**Pod naming:** tasks are named `<repo-slug>-<yyyymmdd>-<4char-random>` (e.g. `myapp-20260308-a3f9`). This is the `<task>` identifier used in all other commands.

**Image auto-detection:** if neither `--image` nor `--auto-build` is given, `ccw start` probes the repo for a `.devcontainer/Dockerfile` and checks the registry cache. If a cached image exists, it's used automatically. If not, you're prompted to build one now.

**Examples:**

```bash
# Basic task on a new branch
ccw start \
  --repo https://github.com/myorg/myapp \
  --branch feat/add-login \
  --prompt "Implement a login form with email/password validation"

# Task linked to a Linear ticket
ccw start \
  --repo https://github.com/myorg/myapp \
  --branch feat/LIN-456 \
  --ticket LIN-456 \
  --prompt "Implement this feature"

# Task with explicit image and auto-build
ccw start \
  --repo https://github.com/myorg/myapp \
  --branch fix/perf \
  --prompt "Profile and optimize the slow database queries" \
  --auto-build
```

---

### `ccw list`

List all worker pods with their status, repo, branch, ticket, age, and node.

```
ccw list
```

Status colors:
- Green: `running`
- Blue: `queued`
- Yellow: `rate-limited`
- Red: `error`
- Dim: `done`

**Example:**

```bash
ccw list

TASK                           STATUS        REPO                 BRANCH                    TICKET       AGE    NODE
myapp-20260308-a3f9            running       myapp                feat/add-login             LIN-456      45m    beelink2
other-20260307-b8c2            done          other                fix/typo                               2h     beelink1
```

---

### `ccw status`

Show detailed status and recent output for a specific task.

```
ccw status <task>
```

Displays task metadata (repo, branch, ticket, node, age) plus the last 30 lines of Claude's output log.

**Example:**

```bash
ccw status myapp-20260308-a3f9
```

---

### `ccw ssh`

Attach to Claude's live tmux session inside a task pod.

```
ccw ssh <task>
```

You'll see Claude's terminal exactly as it runs. Detach without interrupting Claude using `Ctrl+B D`. If Claude has already finished, you'll be offered a plain bash shell.

**Example:**

```bash
ccw ssh myapp-20260308-a3f9
# Detach: Ctrl+B D
```

---

### `ccw shell`

Open a plain bash shell inside a task pod (without attaching to tmux).

```
ccw shell <task>
```

Useful for inspecting the filesystem, reading files, or debugging without interfering with Claude's session.

**Example:**

```bash
ccw shell myapp-20260308-a3f9
```

---

### `ccw logs`

Tail Claude's output log from a task.

```
ccw logs <task> [--follow] [--since <N>]
```

| Option | Description |
|--------|-------------|
| `--follow`, `-f` | Stream new output as it arrives |
| `--since <N>` | Show last N lines (default: 100) |

**Examples:**

```bash
# Show last 100 lines
ccw logs myapp-20260308-a3f9

# Follow live output
ccw logs myapp-20260308-a3f9 --follow

# Show last 50 lines
ccw logs myapp-20260308-a3f9 --since 50
```

---

### `ccw stop`

Send SIGTERM to Claude inside a pod and mark the task as `stopped`. The pod stays alive so you can inspect it.

```
ccw stop <task>
```

**Example:**

```bash
ccw stop myapp-20260308-a3f9
# Pod still exists; use ccw dismiss to remove it
```

---

### `ccw dismiss`

Delete a task pod. Prompts for confirmation if the task is still running.

```
ccw dismiss <task>
```

**Example:**

```bash
ccw dismiss myapp-20260308-a3f9
```

---

### `ccw dismiss-all`

Delete all `done` and `error` pods in one shot.

```
ccw dismiss-all [--include-running]
```

| Option | Description |
|--------|-------------|
| `--include-running` | Also delete running pods (prompts for confirmation) |

**Example:**

```bash
# Clean up all finished pods
ccw dismiss-all

# Clean up everything including running pods
ccw dismiss-all --include-running
```

---

### `ccw queue`

View queue status or manage concurrency.

```
ccw queue
ccw queue set-limit <n>
ccw queue promote <task>
```

| Subcommand | Description |
|------------|-------------|
| *(none)* | Show running/queued/rate-limited counts and current limit |
| `set-limit <n>` | Update `maxConcurrent` in the `worker-config` ConfigMap live |
| `promote <task>` | Immediately promote a queued task to running, bypassing ordering |

**Examples:**

```bash
# Show queue status
ccw queue

# Allow 3 concurrent tasks (up from the default 2)
ccw queue set-limit 3

# Jump a task to the front of the queue
ccw queue promote myapp-20260308-a3f9
```

---

### `ccw follow-up`

Send a follow-up message to Claude's tmux session in a running task.

```
ccw follow-up <task> "<message>"
```

The message is typed into Claude's tmux session. Use this to provide additional context, course-correct, or ask Claude to try a different approach mid-task.

**Example:**

```bash
ccw follow-up myapp-20260308-a3f9 "Actually, use PostgreSQL transactions instead of application-level locking"
```

---

### `ccw feedback`

Show branch info for a task and optionally send feedback.

```
ccw feedback <task>
```

Displays the repo URL and branch so you can find the work, then prompts for optional feedback to send to the session.

---

### `ccw history`

Show the event history for a task or all tasks.

```
ccw history [<task>]
```

**Examples:**

```bash
# History for all tasks
ccw history

# History for a specific task
ccw history myapp-20260308-a3f9
```

---

### `ccw dashboard`

Live-updating terminal overview of all worker activity. Refreshes every 5 seconds.

```
ccw dashboard
```

Displays:
- Queue summary (running/queued/rate-limited counts)
- All running tasks with node, branch, and runtime
- Recently completed tasks

Press `Ctrl+C` to exit.

**Example output:**

```
╔══════════════════════════════════════════════════════════════╗
║  CCW Dashboard                           2026-03-08 14:32:10 ║
╠══════════════════════════════════════════════════════════════╣
║  Queue: 1/2 running   0 queued   0 rate-limited              ║
╠══════════════════════════════════════════════════════════════╣
║  RUNNING                                                     ║
║  myapp-20260308-a3f9   feat/login    beelink2   running 45m  ║
║                                                              ║
║  RECENTLY COMPLETED                                          ║
║  other-20260307-b8c2   fix/typo      beelink1   done 2h ago  ║
╚══════════════════════════════════════════════════════════════╝
Press Ctrl+C to exit. 'ccw ssh <task>' to connect.
```

---

## Workflow Guide

### Typical task lifecycle

```
1. ccw start --repo <url> --branch <name> --prompt "<task>"
   → Pod created, enters queue

2. ccw list
   → See it transition: queued → running

3. ccw logs <task> --follow
   → Watch Claude's output in real time

4. ccw ssh <task>
   → Attach to Claude's tmux session to see the full terminal

5. (optional) ccw follow-up <task> "<correction or extra context>"
   → Send a mid-task message

6. ccw status <task>
   → Check final status and last 30 lines of output

7. Review the branch / open a PR
   → Claude commits its work to the branch you specified

8. ccw dismiss <task>
   → Clean up the pod when done
```

### Working with Linear tickets

```bash
export LINEAR_API_KEY=lin_api_...

ccw start \
  --repo https://github.com/myorg/myapp \
  --branch feat/LIN-123 \
  --ticket LIN-123 \
  --prompt "Implement this ticket"
```

`ccw start` will fetch the ticket title, description, status, assignee, and last 5 comments from Linear and prepend them to Claude's prompt. After Claude finishes, the `on-complete` hook posts a summary comment back to the Linear ticket.

### Building project-specific images

If your repo has a `.devcontainer/Dockerfile`, Claude gets a language-native environment (your exact toolchain). Build it once:

```bash
ccw build --repo https://github.com/myorg/myapp
```

The image is cached in the cluster registry by Dockerfile hash. Subsequent `ccw start` calls detect and use the cached image automatically — no rebuild unless the Dockerfile changes.

### Cleaning up

Done pods accumulate until dismissed. The nightly cleanup CronJob (3am) auto-deletes pods older than 48 hours in `done`, `error`, or `stopped` state. To clean up manually:

```bash
# Remove all finished pods
ccw dismiss-all

# Remove a specific pod
ccw dismiss <task>
```

---

## Configuration

Queue scheduler settings live in the `worker-config` ConfigMap (`agents/worker-config.yaml`). Changes take effect immediately — no restart required.

```bash
# Edit live
kubectl edit configmap worker-config -n claude-workers

# Or apply from file after editing
kubectl apply -f agents/worker-config.yaml
```

| Key | Default | Description |
|-----|---------|-------------|
| `maxConcurrent` | `"2"` | Maximum simultaneously running Claude sessions. Increase if your Anthropic plan supports higher concurrency. |
| `rateLimitCooldownMinutes` | `"300"` | Minutes to wait after a rate limit before retrying. 300 minutes (5 hours) matches Claude's rolling usage window. |
| `podTTLHours` | `"48"` | Pods in terminal states (`done`, `error`, `stopped`) older than this are deleted by the nightly cleanup CronJob. |

### Environment variables for `ccw`

| Variable | Default | Description |
|----------|---------|-------------|
| `CCW_HOMELAB_DIR` | `~/homelab` | Path to a cloned homelab repo. Used to find `pod-template.yaml` and `build-job-template.yaml` when `ccw` is installed outside the repo (e.g. via dotfiles). |
| `CCW_POD_TEMPLATE` | *(auto)* | Explicit override for the pod template path. |
| `CCW_BUILD_JOB_TEMPLATE` | *(auto)* | Explicit override for the build job template path. |
| `CCW_REGISTRY` | `registry.claude-workers.svc.cluster.local:5000` | In-cluster registry address. |
| `LINEAR_API_KEY` | *(none)* | Required for `--ticket` Linear integration. |

---

## Troubleshooting

### Pod stuck in `queued`

**Symptom:** `ccw list` shows a pod as `queued` indefinitely.

**Causes and fixes:**

1. **Scheduler not running:**
   ```bash
   kubectl get pods -n claude-workers -l app=claude-scheduler
   kubectl logs -n claude-workers -l app=claude-scheduler
   ```
   If crashed, describe the pod and check the logs for errors.

2. **`maxConcurrent` limit reached:**
   ```bash
   ccw queue
   ```
   If running == maxConcurrent, the pod is correctly waiting. Either wait for a task to finish, or increase the limit:
   ```bash
   ccw queue set-limit 3
   ```

3. **All running pods are rate-limited:**
   Rate-limited pods occupy a running slot. Wait for the cooldown (default 5 hours) or reduce the limit temporarily.

---

### Claude not starting inside the pod

**Symptom:** pod is `running` but `ccw logs <task>` shows no output, or the tmux session doesn't exist.

**Fixes:**

1. Check pod events:
   ```bash
   kubectl describe pod -n claude-workers <task>
   ```

2. Check the entrypoint logs:
   ```bash
   kubectl logs -n claude-workers <task>
   ```

3. The pod may still be cloning the repo (first step). Give it 30-60 seconds, then check again.

4. If the repo clone failed, logs will show a git error. Common cause: `GITHUB_TOKEN` secret is missing or expired.
   ```bash
   kubectl get secret -n claude-workers claude-worker-secrets
   ```

---

### Rate limit errors

**Symptom:** pod transitions to `rate-limited` status.

Claude's API returns a rate limit error, typically after heavy usage within a 5-hour rolling window. The scheduler automatically parks rate-limited pods and retries after the cooldown period (`rateLimitCooldownMinutes`, default 300).

**To check:**
```bash
ccw queue         # shows rate-limited count
ccw list          # shows which pods are rate-limited
ccw logs <task>   # shows the rate limit error message
```

**To recover faster:** reduce the cooldown (not recommended — you'll just hit limits again) or wait it out.

---

### Registry issues

**Symptom:** `ccw build` fails, or pods fail to pull images with `ImagePullBackOff`.

1. **Verify the registry pod is running:**
   ```bash
   kubectl get pods -n claude-workers -l app=registry
   kubectl logs -n claude-workers -l app=registry
   ```

2. **Check the registry is reachable from the cluster:**
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl -n claude-workers --restart=Never -- \
     curl http://registry.claude-workers.svc.cluster.local:5000/v2/
   # Expected: {}
   ```

3. **Nodes not configured to trust the registry:**
   This is the most common cause of `ImagePullBackOff` for registry images. Re-run the setup script:
   ```bash
   bash agents/scripts/setup-registry-nodes.sh
   ```

4. **PVC not bound (Longhorn not installed):**
   ```bash
   kubectl get pvc -n claude-workers
   ```
   The registry PVC requires Longhorn. If it's `Pending`, check Longhorn is installed and healthy.

---

### Image build failures

**Symptom:** `ccw build` exits with an error; the build job fails.

1. **Check build job logs:**
   ```bash
   # Find the build job name (build-<slug>-<hash>)
   kubectl get jobs -n claude-workers
   kubectl logs -n claude-workers -l "job-name=build-<name>" --all-containers
   ```

2. **Clone stage fails:** GitHub token missing or insufficient permissions. The `GITHUB_TOKEN` in the secret needs `repo` read access.

3. **Build stage fails (Kaniko):** the `.devcontainer/Dockerfile` has a syntax error or references a base image that can't be pulled.

4. **Push stage fails:** registry not reachable from within the cluster. Check the registry pod and nodes are configured (see [Registry issues](#registry-issues)).

5. **Force a clean rebuild:**
   ```bash
   ccw build --repo <url> --no-cache
   ```

---

### Linear integration not working

**Symptom:** `--ticket` flag silently skips or errors; no completion comment posted to Linear.

1. **`LINEAR_API_KEY` not set:**
   ```bash
   echo $LINEAR_API_KEY
   ```
   The key must be set in your shell environment when running `ccw start`.

2. **Wrong ticket ID format:** Linear IDs look like `LIN-123`. The query uses the issue's human-readable identifier.

3. **Completion hook not running:** check the pod hooks directory and the `on-complete.sh` script is present in the base image at `/home/claude/.claude/hooks/`.

---

### `ccw` can't find pod template

**Symptom:** `error: pod template not found: ...`

`ccw` looks for `pod-template.yaml` relative to the script, or at `$CCW_HOMELAB_DIR/agents/pod-template.yaml`.

```bash
# Set the homelab dir in your shell config
export CCW_HOMELAB_DIR=~/homelab

# Or set an explicit path
export CCW_POD_TEMPLATE=/path/to/agents/pod-template.yaml
```

---

## Resource Planning

### Per-pod resource usage

Each worker pod requests:

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | ~0.25 cores (idle) to ~1 core (active) | no hard limit |
| RAM | ~512Mi (Node.js + Claude Code) | ~2Gi peak |

Claude itself is a CLI tool making API calls — it doesn't do heavy local computation. CPU usage spikes only when running tests or build tools inside the repo.

### Cluster capacity

Each node has 16GB RAM and 4 CPU cores (Intel N100), with ~12-14GB usable for workloads after system overhead.

| Metric | Value |
|--------|-------|
| Nodes | 3 |
| Usable RAM per node | ~13GB |
| Safe concurrent tasks per node | 4-6 |
| Cluster-wide maximum | ~12-18 tasks |

**Recommended starting point:** `maxConcurrent: 2` (one active task per node for the first two nodes, leaving one node free for other workloads).

**For Claude-heavy workloads:** 4-6 concurrent tasks is reasonable. The bottleneck is typically the Anthropic API rate limit, not cluster resources.

### Scheduler footprint

The scheduler Deployment uses minimal resources (~50Mi RAM, <0.1 CPU) and doesn't scale with the number of tasks.

### Registry storage

The in-cluster registry uses a 20Gi Longhorn PVC. Each cached devcontainer image is typically 1-4GB. With the overlay layer (~50MB), you can cache ~5-15 project images before storage becomes a concern. To free space, delete unused images via the registry API or redeploy the PVC.
