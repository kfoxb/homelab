# Autonomous Claude Code Development Platform

## Goal

Automate code development in a project-agnostic way so that Claude Code agents can work autonomously and in conjunction with human engineers to efficiently develop software projects.

## Architecture

Each task is a Kubernetes **Pod** (not a Job) in the `claude-workers` namespace. Pods stay alive for human interaction after Claude finishes. Claude Code runs inside a **tmux** session so humans can SSH in, observe, and continue working with Claude.

Key components:

- **Base image** — container image with Claude Code, tmux, git, GitHub CLI, and dotfiles pre-installed
- **`ccw` CLI** — bash script for humans to start, monitor, SSH into, and stop tasks; lives in kfoxb/dotfiles
- **Queue scheduler** — small Deployment that enforces concurrency limits and handles API usage limit recovery
- **In-cluster registry** — `registry:2` with Longhorn storage for caching built devcontainer images
- **Devcontainer overlay** — Kaniko-based image building that layers Claude tooling on top of project devcontainers

## Workflow

1. Human runs `ccw start --repo <url> --branch <branch> [--ticket LIN-123] --prompt "..."`
2. Pod is created, queued if at concurrency limit, then released
3. Entrypoint clones repo, checks out branch, starts Claude in tmux
4. Claude works, pushes commits to the branch
5. Human runs `ccw list` to see what's happening, `ccw ssh <task>` to interact
6. Human pulls the branch locally, tests, runs `ccw feedback <task> "..."` with follow-up
7. When satisfied, `ccw dismiss <task>` cleans up the pod

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pod vs Job | Pod | Jobs terminate; pods stay alive for human SSH/interaction |
| CLI language | Bash script | No build step, no runtime dependency, easy to install anywhere |
| API auth | Claude Pro/Max subscription | Predictable cost; queue system manages limits |
| Container registry | Local in-cluster (registry:2) | Avoids internet round-trips for large devcontainer images |
| CLI distribution | kfoxb/dotfiles repo | Available everywhere dotfiles are installed |
| Session persistence | tmux inside pod | Survives Claude restarts; humans can attach/detach |

## Phases

| Phase | Name | Delivers |
|-------|------|----------|
| [1](./phase-1-foundation/) | Foundation | Working base image, secrets, ability to manually launch a pod |
| [2](./phase-2-cli/) | CLI Core | `ccw` script: start, list, ssh, stop |
| [3](./phase-3-queue-and-limits/) | Queue & Limits | Concurrency control, usage limit recovery |
| [4](./phase-4-session-management/) | Session Management | Resume, status tracking, follow-up, feedback workflow |
| [5](./phase-5-devcontainer-images/) | Devcontainer Images | Per-project image builds via Kaniko |
| [6](./phase-6-polish-and-linear/) | Polish & Linear | Linear integration, dashboard, docs, dotfiles distribution |

## Resource Budget

- Each worker pod: 500m–2000m CPU, 1–4Gi RAM
- 3 nodes × ~14GB available ≈ 42GB total, ~12 cores
- `maxConcurrent: 2` default (conservative; leaves room for other workloads)
- Registry PVC: 20Gi on Longhorn

## Future Iterations (Out of Scope)

- **Docker Compose support** — future: sidecar containers or pod-level compose for multi-container devcontainers
- **GitHub App auth** — more secure than PAT; upgrade when warranted
- **Webhook-triggered tasks** — auto-create tasks from PR comments or GitHub webhooks
- **Multi-user support** — namespace-per-user extension path
