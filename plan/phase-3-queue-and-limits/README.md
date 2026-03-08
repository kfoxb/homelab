# Phase 3: Queue and Usage Limit Management

## Goal

Prevent overloading the Anthropic API by enforcing concurrency limits, and handle subscription usage limits gracefully with automatic recovery — so background tasks don't require babysitting.

## What Gets Built

- **Queue scheduler** — a Deployment that runs a loop every 30 seconds, promoting queued pods to running when under the concurrency limit
- **ConfigMap** with adjustable settings (maxConcurrent, rateLimitCooldownMinutes)
- **Queue-aware entrypoint** — pods start in a "waiting" state and don't launch Claude until the scheduler releases them
- **Claude Code hooks** — a `Stop` hook inside the container detects rate limit exits and updates the pod label
- **Rate limit recovery** — the scheduler re-queues rate-limited pods after the cooldown period
- **`ccw queue` subcommand** — show queue state and adjust concurrency

## Architecture

### Pod States

```
queued → running → done
                 → error
                 → rate-limited → (auto re-queues after cooldown) → running
                 → stopped      (human stopped it)
```

### Queuing Mechanism

When `ccw start` creates a pod, it starts with label `status=queued`. The entrypoint script polls for this label to change to `running` before launching Claude:

```bash
# In entrypoint.sh - wait for scheduler to release us
while true; do
  STATUS=$(kubectl get pod "$HOSTNAME" -n claude-workers \
    -o jsonpath='{.metadata.labels.status}')
  if [ "$STATUS" = "running" ]; then break; fi
  sleep 5
done
# Now start Claude...
```

The scheduler patches the label: `kubectl label pod <name> status=running --overwrite`

### Scheduler Logic

A bash loop in a Deployment (not a CronJob — Deployments restart automatically):

```
every 30 seconds:
  count = number of pods with status=running
  limit = worker-config.data.maxConcurrent

  if count < limit:
    candidate = oldest pod with status=queued (by creationTimestamp)
    if candidate exists:
      patch candidate: status=running

  for each pod with status=rate-limited:
    retryAfter = pod annotation "ccw/retry-after" (unix timestamp)
    if now > retryAfter:
      patch pod: status=queued  # re-queues it for the scheduler
```

### Rate Limit Detection

Claude Code's exit codes and output patterns for rate limits need to be detected by a hook or wrapper script. The entrypoint wraps the Claude invocation:

```bash
claude --dangerously-skip-permissions ... 2>&1 | tee /workspace/.claude-output.log
EXIT_CODE=${PIPESTATUS[0]}

# Check for rate limit signals in output
if grep -q "rate limit\|usage limit\|overloaded" /workspace/.claude-output.log; then
  RETRY_AFTER=$(date -d "+5 hours" +%s)
  kubectl annotate pod "$HOSTNAME" ccw/retry-after="$RETRY_AFTER" --overwrite
  kubectl label pod "$HOSTNAME" status=rate-limited --overwrite
else
  # normal exit handling
fi
```

Claude Code also supports a `Stop` hook that runs when Claude exits. This is a script placed at `~/.claude/hooks/stop.sh` (or configured in `~/.claude/settings.json`). The hook receives exit context via stdin as JSON.

### ConfigMap: worker-config

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker-config
  namespace: claude-workers
data:
  maxConcurrent: "2"
  rateLimitCooldownMinutes: "300"  # 5 hours - matches Claude's rolling window
```

### `ccw queue` Output

```
Queue Status
  Running: 2/2 (at limit)
  Queued:  3
  Rate-limited: 1 (retry in 2h 15m)

Queued tasks (oldest first):
  other-app-20240315-c1d2    feat/refactor    queued 45m
  third-20240315-e4f5        main             queued 32m
  fourth-20240315-g7h8       feat/new         queued 18m
```

## Files

```
agents/
  worker-config.yaml          # ConfigMap with settings
  scheduler/
    deployment.yaml           # Queue scheduler Deployment
    entrypoint.sh             # Scheduler loop logic
  base-image/
    hooks/
      on-stop.sh              # Rate limit detection hook
    entrypoint.sh             # Updated: queue-aware wait loop
```

## Tickets

See [tickets.json](./tickets.json).

| # | Title |
|---|-------|
| 3.1 | Create worker-config ConfigMap |
| 3.2 | Implement queue-aware entrypoint wait loop |
| 3.3 | Build queue scheduler Deployment |
| 3.4 | Add Claude Code hooks for usage limit detection |
| 3.5 | Implement rate limit recovery in scheduler |
| 3.6 | Add `ccw queue` CLI subcommand |

## Verification

```bash
# Set low concurrency limit for testing
kubectl patch configmap worker-config -n claude-workers \
  --patch '{"data":{"maxConcurrent":"1"}}'

# Start 3 tasks
ccw start --repo <url> --branch feat/a --prompt "count files"
ccw start --repo <url> --branch feat/b --prompt "count files"
ccw start --repo <url> --branch feat/c --prompt "count files"

# Check queue
ccw queue
# Expected: 1 running, 2 queued

# Watch as tasks complete and queued ones start
watch ccw list

# Simulate rate limit (manually label a running pod)
kubectl label pod <task> -n claude-workers status=rate-limited --overwrite
kubectl annotate pod <task> -n claude-workers ccw/retry-after=$(date -d "+2 minutes" +%s) --overwrite

# Watch it get re-queued after cooldown
watch ccw list
```

## Dependencies

- Phase 1: base image, namespace, pod template
- Phase 2: ccw CLI (for `ccw queue` subcommand)
