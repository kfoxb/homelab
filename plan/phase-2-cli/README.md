# Phase 2: CLI Core (`ccw`)

## Goal

Give humans a convenient tool to start tasks, monitor them, connect, and clean up — without needing to know kubectl internals. A single bash script called `ccw` (Claude Code Worker) that wraps kubectl operations.

## What Gets Built

- `agents/cli/ccw` — single bash script with subcommands
- `agents/cli/install.sh` — installer that puts `ccw` on PATH

### Subcommands

```
ccw start   --repo <url> --branch <branch> [--ticket <id>] --prompt "..."
ccw list
ccw status  <task>
ccw ssh     <task>
ccw shell   <task>
ccw logs    <task> [--follow]
ccw stop    <task>
ccw dismiss <task>
ccw dismiss-all
```

## Architecture

### Single-file bash script

No build step, no runtime dependency beyond `kubectl` and `jq`. The script uses:
- `kubectl get pods -n claude-workers` with `-l app=claude-worker` and custom output formats
- `kubectl exec -it` for SSH and shell access
- `kubectl delete pod` for dismiss
- `envsubst` + `kubectl apply` for pod creation
- `kubectl exec -- cat` for log reading

### Task names

`ccw start` generates a task name from a short slug of the repo + a timestamp:
```
<repo-slug>-<yyyymmdd>-<4-char-random>
e.g. my-app-20240315-a3f9
```

Task names are also used as pod names (max 63 chars, lowercase, alphanumeric + hyphens).

### Repo slug

The repo slug is extracted from the URL: `https://github.com/user/my-app` → `my-app`. If the pod name would exceed 63 chars, the repo slug is truncated.

### Template resolution

The script resolves the pod template path from `$CCW_POD_TEMPLATE` env var or defaults to the relative path `../pod-template.yaml` from the script's location. This allows it to work from dotfiles or from within the homelab repo.

### `ccw list` output

```
TASK                      STATUS    REPO           BRANCH              AGE    NODE
my-app-20240315-a3f9     running   my-app         feat/login          14m    beelink2
other-20240314-b8c2      done      other-project  fix/typo            2h     beelink1
```

### `ccw status` output

```
Task:     my-app-20240315-a3f9
Status:   running
Repo:     https://github.com/user/my-app
Branch:   feat/login
Ticket:   LIN-234
Node:     beelink2
Age:      14m
Pod IP:   10.42.1.15

--- Last 20 lines of Claude output ---
<tail of /workspace/.claude-output.log>
```

## Files

```
agents/cli/
  ccw           # Main script
  install.sh    # Copies ccw to ~/.local/bin/ccw
```

## Tickets

See [tickets.json](./tickets.json).

| # | Title |
|---|-------|
| 2.1 | Scaffold ccw bash CLI with help and argument parsing |
| 2.2 | Implement `ccw start` |
| 2.3 | Implement `ccw list` |
| 2.4 | Implement `ccw status` |
| 2.5 | Implement `ccw ssh` and `ccw shell` |
| 2.6 | Implement `ccw logs` |
| 2.7 | Implement `ccw stop` and `ccw dismiss` |

## Verification

```bash
# Install
bash agents/cli/install.sh
which ccw

# Start a task
ccw start --repo https://github.com/user/my-app \
          --branch feat/test-ccw \
          --prompt "Read the README and summarize the project"

# Check it
ccw list
ccw status my-app-<date>-<id>

# Connect
ccw ssh my-app-<date>-<id>   # attaches to Claude's tmux session

# Tail logs
ccw logs my-app-<date>-<id> --follow

# Cleanup
ccw dismiss my-app-<date>-<id>
```

## Dependencies

- Phase 1 must be complete (namespace, secrets, pod template, base image)
