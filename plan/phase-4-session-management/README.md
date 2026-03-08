# Phase 4: Session Management and Observability

## Goal

Make the system robust for multi-day tasks: Claude can resume where it left off after a rate limit hit, pod status accurately reflects what's happening, humans can send follow-up instructions without SSH-ing in, and there's a clear event history for debugging.

## What Gets Built

- **Session ID capture and resume** — entrypoint saves Claude's session ID; re-launches use `claude --resume`
- **Status monitor** — background process in each pod that accurately tracks Claude's state
- **`ccw follow-up`** — send additional prompts to a running or idle Claude session
- **Event logging** — structured lifecycle events per pod, readable with `ccw history`
- **`ccw feedback`** — high-level workflow command for the pull-test-feedback loop

## Architecture

### Session Resume Flow

Claude Code's `--output-format stream-json` outputs an `init` event with the session ID:
```json
{"type":"system","subtype":"init","session_id":"abc123","..."}
```

The entrypoint captures this:
```bash
SESSION_ID_FILE=/tmp/claude-session-id

claude --dangerously-skip-permissions \
       --output-format stream-json \
       "$INITIAL_PROMPT" 2>&1 | \
  tee /workspace/.claude-output.log | \
  while IFS= read -r line; do
    # Extract session ID from init event
    if echo "$line" | jq -e '.subtype == "init"' >/dev/null 2>&1; then
      echo "$line" | jq -r '.session_id' > "$SESSION_ID_FILE"
    fi
    echo "$line"
  done
```

On restart (rate limit recovery), the entrypoint checks for the file:
```bash
if [ -f "$SESSION_ID_FILE" ]; then
  SESSION_ID=$(cat "$SESSION_ID_FILE")
  RESUME_FLAG="--resume $SESSION_ID"
  PROMPT="Continue where you left off."
else
  RESUME_FLAG=""
  PROMPT="$INITIAL_PROMPT"
fi

claude --dangerously-skip-permissions $RESUME_FLAG \
       --output-format stream-json "$PROMPT" ...
```

### Status Monitor

A background process (`status-monitor.sh`) runs alongside the entrypoint and updates the pod label based on observed state:

```
every 10 seconds:
  if tmux session 'claude' exists:
    if claude process is running in tmux:
      status = running (no change needed)
    else:
      # tmux session exists but claude exited - waiting for human
      status = waiting-input
  else:
    # tmux session gone
    if /tmp/claude-done exists:
      status = done (or error, based on exit code file)
    else:
      status = error (unexpected exit)
```

The "waiting-input" state means Claude finished its response and is waiting at the interactive prompt. This is important for the `ccw follow-up` workflow.

### Event Log

Each pod writes lifecycle events to `/workspace/.claude-events.log`:
```
2024-03-15T10:00:00Z STARTED task=my-app-20240315-a3f9 repo=https://... branch=feat/login
2024-03-15T10:00:05Z CLONED repo=https://... elapsed=5s
2024-03-15T10:00:06Z BRANCH_CHECKED_OUT branch=feat/login
2024-03-15T10:00:07Z CLAUDE_STARTED session_id=abc123
2024-03-15T14:32:10Z RATE_LIMITED retry_after=2024-03-15T19:32:10Z
2024-03-15T19:32:15Z RESUMED session_id=abc123 prompt="continue"
2024-03-15T20:45:00Z CLAUDE_DONE exit_code=0
2024-03-15T20:45:01Z FOLLOW_UP prompt="actually also fix the tests"
2024-03-15T20:52:00Z CLAUDE_DONE exit_code=0
```

`ccw history <task>` reads this file. `ccw history` (no task) aggregates recent events across all pods.

### `ccw follow-up`

Sends a follow-up prompt to Claude in a running or idle pod:

```bash
ccw follow-up <task> "fix the failing tests too"
```

Implementation:
1. Check pod status
2. If `waiting-input` or `done`: send new prompt via `kubectl exec -- tmux send-keys -t claude "<prompt>" Enter`
3. If `running`: queue the message — write to `/tmp/follow-up-queue` in the pod; the entrypoint picks it up after Claude finishes its current response
4. Append `FOLLOW_UP` event to event log

### `ccw feedback`

High-level command for the pull-test-feedback loop:
```bash
ccw feedback <task> "the login tests are failing with error XYZ"
```

Shows branch info first, then sends as follow-up:
```
Task:   my-app-20240315-a3f9
Branch: feat/login
Latest: abc1234 - "Add login form validation"

Sending feedback...
```

## Files

```
agents/
  base-image/
    entrypoint.sh         (updated: session capture, resume, event logging)
    status-monitor.sh     (new: background label updater)
  cli/
    ccw                   (updated: follow-up, history, feedback subcommands)
```

## Tickets

See [tickets.json](./tickets.json).

| # | Title |
|---|-------|
| 4.1 | Implement session ID capture and resume |
| 4.2 | Build pod status monitor |
| 4.3 | Implement pod event logging |
| 4.4 | Implement `ccw follow-up` |
| 4.5 | Implement `ccw history` |
| 4.6 | Implement `ccw feedback` |

## Verification

```bash
# Start a task
ccw start --repo <url> --branch feat/test --prompt "implement a simple counter"

# Follow its progress
ccw logs my-app-<id> --follow

# When Claude is idle (status=waiting-input), send follow-up
ccw follow-up my-app-<id> "also add unit tests for the counter"

# Check event history
ccw history my-app-<id>

# Test rate limit recovery (simulate by manually labeling + annotating)
kubectl label pod my-app-<id> -n claude-workers status=rate-limited --overwrite
kubectl annotate pod my-app-<id> -n claude-workers \
  ccw/retry-after=$(date -d "+1 minute" +%s) --overwrite
# Wait 1 minute, verify Claude resumes with session resume
ccw history my-app-<id>  # should show RESUMED event
```

## Dependencies

- Phase 1: base image, entrypoint
- Phase 2: ccw CLI (for new subcommands)
- Phase 3: rate limit recovery (the resume is triggered by the scheduler from Phase 3)
