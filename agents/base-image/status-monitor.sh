#!/usr/bin/env bash
# Background process that tracks Claude's state and updates the pod label.
# Launched by entrypoint.sh alongside the main work loop.
#
# Polls every 10 seconds and applies these transitions:
#   tmux alive + claude process running  → (no change, still running)
#   tmux alive + no claude process       → waiting-input
#   tmux gone  + /tmp/claude-done        → done (exit 0) or error (non-zero)
#   tmux gone  + no /tmp/claude-done     → error (unexpected exit)
#
# Only patches the pod label when the value actually changes.
# Does not interfere with rate-limited state (managed by the entrypoint).

set -uo pipefail

NAMESPACE="${POD_NAMESPACE:-claude-workers}"
DONE_FILE="/tmp/claude-done"
POLL_INTERVAL=10

CURRENT_LABEL=""
PREV_LABEL=""
# Track whether we've seen the tmux session at least once this cycle.
# Prevents false "error" labels while the entrypoint is still in setup.
SEEN_TMUX=false

_get_current_label() {
  kubectl get pod "$HOSTNAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.status}' 2>/dev/null || echo ""
}

_set_label() {
  local new_status="$1"
  if [[ "$new_status" == "$CURRENT_LABEL" ]]; then
    return 0
  fi
  if kubectl label pod "$HOSTNAME" -n "$NAMESPACE" \
      "status=${new_status}" --overwrite 2>/dev/null; then
    echo "[status-monitor] status: ${CURRENT_LABEL} → ${new_status}"
    CURRENT_LABEL="$new_status"
  else
    echo "[status-monitor] Warning: failed to set status=${new_status}" >&2
  fi
}

_cleanup() {
  echo "[status-monitor] caught termination signal, exiting"
  exit 0
}
trap _cleanup SIGTERM SIGINT

CURRENT_LABEL=$(_get_current_label)
echo "[status-monitor] started (pod=${HOSTNAME}, current status=${CURRENT_LABEL})"

while true; do
  sleep "$POLL_INTERVAL"

  CURRENT_LABEL=$(_get_current_label)

  # When the scheduler releases a pod from rate-limited back to running, a new
  # Claude cycle is beginning. Reset SEEN_TMUX so we don't flag an error during
  # the gap before entrypoint starts the new tmux session.
  if [[ "$PREV_LABEL" == "rate-limited" && "$CURRENT_LABEL" == "running" ]]; then
    echo "[status-monitor] rate-limit cycle ended, resetting tmux tracker"
    SEEN_TMUX=false
  fi
  PREV_LABEL="$CURRENT_LABEL"

  # Let the entrypoint own rate-limited state transitions.
  if [[ "$CURRENT_LABEL" == "rate-limited" ]]; then
    continue
  fi

  if tmux has-session -t claude 2>/dev/null; then
    SEEN_TMUX=true

    if pgrep -f 'claude ' > /dev/null 2>&1; then
      # Claude process is running — no label change needed
      :
    else
      # tmux is alive but Claude exited — session is waiting for human input
      _set_label "waiting-input"
    fi
  else
    # tmux session is gone
    if [[ "$SEEN_TMUX" == "false" ]]; then
      # Entrypoint hasn't started the tmux session yet — nothing to report
      continue
    fi

    if [[ -f "$DONE_FILE" ]]; then
      EXIT_CODE=$(cat "$DONE_FILE" 2>/dev/null | tr -d '[:space:]')
      if [[ "$EXIT_CODE" == "0" ]]; then
        _set_label "done"
      else
        _set_label "error"
      fi
    else
      # tmux gone without a done file — unexpected exit
      _set_label "error"
    fi

    # Terminal state reached — stop polling
    echo "[status-monitor] terminal state reached, exiting"
    break
  fi
done
