# Phase 6: Workflow Polish and Linear Integration

## Goal

Make the system genuinely pleasant to use day-to-day: Linear ticket context flows into Claude's work, completion summaries flow back to Linear, a dashboard gives instant visibility, `ccw` is installed via dotfiles everywhere it's needed, and the whole thing is documented.

## What Gets Built

- **Linear integration** — fetch ticket details for context; post completion summaries back
- **`ccw dashboard`** — live-updating terminal overview of all worker activity
- **Dotfiles distribution** — `ccw` installed automatically in kfoxb/dotfiles
- **Auto-cleanup CronJob** — removes stale done/error pods
- **Full documentation** — updated `agents/README.md` with architecture, setup, CLI reference

## Architecture

### Linear Integration

#### Fetching Ticket Context

When `ccw start --ticket LIN-123` is provided, fetch the ticket from Linear's GraphQL API before creating the pod. The fetched data (title, description, recent comments) is written to a file in the pod, and the entrypoint prepends it to Claude's initial prompt.

```bash
# In ccw start, if --ticket is provided
TICKET_CONTEXT=$(fetch_linear_ticket "$TICKET_ID")
# Write to a ConfigMap or pass as env var (truncated to fit)
```

Linear GraphQL query:
```graphql
query GetIssue($id: String!) {
  issue(id: $id) {
    title
    description
    state { name }
    assignee { name }
    comments { nodes { body createdAt user { name } } }
  }
}
```

The context is prepended to Claude's prompt:
```
LINEAR TICKET: LIN-123
Title: Fix login form validation
Status: In Progress
Description: ...

Previous comments:
...

---

YOUR TASK:
<original user prompt>
```

#### Posting Completion Summaries

A hook in the pod (`hooks/on-complete.sh`) runs when Claude finishes (status transitions to `done`). It asks Claude to summarize what was accomplished (via a short claude invocation), then posts to Linear:

```bash
# Get summary from Claude
SUMMARY=$(claude -p "In 2-3 sentences, summarize what you just accomplished. Be specific about what files were changed and what the result is." --max-turns 1)

# Post to Linear
curl -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { commentCreate(input: { issueId: \\\"$ISSUE_ID\\\", body: \\\"$SUMMARY\\\" }) { success } }\"}"
```

### `ccw dashboard`

A live-updating terminal view using `watch` semantics (clear + redraw every 5 seconds):

```
╔══════════════════════════════════════════════════════════════╗
║  CCW Dashboard                           2024-03-15 14:32:10 ║
╠══════════════════════════════════════════════════════════════╣
║  Queue: 1/2 running   0 queued   0 rate-limited              ║
╠══════════════════════════════════════════════════════════════╣
║  RUNNING                                                     ║
║  my-app-20240315-a3f9   feat/login    beelink2   running 45m ║
║                                                              ║
║  RECENTLY COMPLETED                                          ║
║  other-20240314-b8c2    fix/typo      beelink1   done 2h ago ║
╚══════════════════════════════════════════════════════════════╝
Press Ctrl+C to exit. 'ccw ssh <task>' to connect.
```

Uses `tput` for box drawing and colors. Refreshes every 5 seconds.

### Dotfiles Distribution

The `ccw` script is copied into the `kfoxb/dotfiles` repository:
- Added at `bin/ccw` in the dotfiles repo
- The dotfiles install script adds `~/dotfiles/bin` to PATH (or symlinks to `~/.local/bin/ccw`)
- On each dotfiles install, `ccw` is available immediately

The script needs one configuration: path to the homelab repo for `pod-template.yaml`. This is handled by an env var `CCW_HOMELAB_DIR` which the dotfiles can set in `.zshrc`/`.bashrc`, defaulting to `~/homelab`.

### Auto-Cleanup CronJob

A CronJob runs nightly that deletes pods in terminal states (done, error, stopped) that are older than the configured TTL:

```yaml
schedule: "0 3 * * *"  # 3am daily
```

Default TTL: 48 hours. Configurable via worker-config ConfigMap key `podTTLHours`.

## Files

```
agents/
  cleanup-cronjob.yaml              # Nightly cleanup CronJob
  base-image/
    hooks/
      on-complete.sh                # Post to Linear on completion
  cli/
    ccw                             (update: dashboard, linear integration)
  README.md                         (full rewrite)
```

## Tickets

See [tickets.json](./tickets.json).

| # | Title |
|---|-------|
| 6.1 | Implement Linear ticket context fetching in `ccw start` |
| 6.2 | Implement Linear completion hook |
| 6.3 | Implement `ccw dashboard` |
| 6.4 | Distribute `ccw` via kfoxb/dotfiles |
| 6.5 | Add auto-cleanup CronJob |
| 6.6 | Write comprehensive documentation |

## Verification

```bash
# Test Linear integration
ccw start --repo <url> --branch feat/test \
          --ticket LIN-123 \
          --prompt "implement this"
# Verify: Claude's tmux session shows the ticket context in its initial prompt
# Verify: After finishing, a comment appears on LIN-123 in Linear

# Test dashboard
ccw dashboard
# Start 2 tasks, verify they appear and status updates live

# Test dotfiles install
# On a fresh devcontainer or SSH into a beelink node:
# Install dotfiles, verify ccw is on PATH
which ccw
ccw --help

# Verify cleanup
# Manually age a done pod's label (can't change creationTimestamp,
# but cleanup script can be tested with a --dry-run flag)
```

## Dependencies

- All previous phases
- Linear API key needed (add `LINEAR_API_KEY` to secrets)
- Access to kfoxb/dotfiles repo to open PR
