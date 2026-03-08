#!/usr/bin/env bash
set -euo pipefail

# ─── Git credentials ─────────────────────────────────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git config --global credential.helper store
  echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
  chmod 600 ~/.git-credentials
fi

# ─── Wait for scheduler to release this pod ──────────────────────────────────
echo "Waiting for queue release..."
while true; do
  STATUS=$(kubectl get pod "$HOSTNAME" -n "${POD_NAMESPACE:-claude-workers}" \
    -o jsonpath='{.metadata.labels.status}' 2>/dev/null)
  [ "$STATUS" = "running" ] && break
  sleep 5
done
echo "Released by scheduler, starting work..."

# ─── Clone repo ───────────────────────────────────────────────────────────────
echo "Cloning ${REPO_URL} ..."
git clone "${REPO_URL}" /workspace
cd /workspace

# ─── Checkout / create branch ─────────────────────────────────────────────────
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's|refs/remotes/origin/||' || echo "main")

if git ls-remote --exit-code --heads origin "${GIT_BRANCH}" > /dev/null 2>&1; then
  git checkout "${GIT_BRANCH}"
  git pull --ff-only origin "${GIT_BRANCH}" || true
else
  echo "Branch '${GIT_BRANCH}' not found remotely — creating from '${DEFAULT_BRANCH}'"
  git checkout -b "${GIT_BRANCH}" "origin/${DEFAULT_BRANCH}"
fi

# ─── Write initial CLAUDE.md context if provided ──────────────────────────────
if [[ -n "${CLAUDE_PROMPT_FILE:-}" && -f "${CLAUDE_PROMPT_FILE}" ]]; then
  cp "${CLAUDE_PROMPT_FILE}" /workspace/CLAUDE.md
fi

# ─── SIGTERM handler ──────────────────────────────────────────────────────────
_shutdown() {
  echo "SIGTERM received — shutting down Claude gracefully"
  # Send SIGTERM to tmux session if it still exists
  if tmux has-session -t claude 2>/dev/null; then
    tmux send-keys -t claude C-c 2>/dev/null || true
    # Give Claude up to 25 seconds to finish before killing
    for i in $(seq 1 25); do
      tmux has-session -t claude 2>/dev/null || break
      sleep 1
    done
    tmux kill-session -t claude 2>/dev/null || true
  fi
  exit 0
}
trap _shutdown SIGTERM

# ─── Start Claude in a tmux session ──────────────────────────────────────────
echo "Starting Claude Code in tmux session 'claude' ..."
tmux new-session -d -s claude \
  "set -o pipefail; claude --dangerously-skip-permissions --output-format stream-json 2>&1 | tee /workspace/.claude-output.log; echo \$? > /tmp/claude-exit-code"

# ─── Background monitor ───────────────────────────────────────────────────────
# Polls until the tmux session exits, then writes /tmp/claude-done and
# updates the pod's status label via kubectl.
_monitor() {
  # Wait for tmux session to disappear
  while tmux has-session -t claude 2>/dev/null; do
    sleep 5
  done

  EXIT_CODE=0
  if [[ -f /tmp/claude-exit-code ]]; then
    EXIT_CODE=$(cat /tmp/claude-exit-code)
  fi

  echo "${EXIT_CODE}" > /tmp/claude-done

  if [[ "${EXIT_CODE}" -eq 0 ]]; then
    STATUS="done"
  else
    STATUS="error"
  fi

  echo "Claude exited with code ${EXIT_CODE} — updating pod label status=${STATUS}"

  # Update own pod label; HOSTNAME is the pod name in Kubernetes
  kubectl label pod "${HOSTNAME}" \
    -n "${POD_NAMESPACE:-claude-workers}" \
    "status=${STATUS}" \
    --overwrite 2>/dev/null || \
    echo "Warning: could not update pod label (kubectl may not be available)"
}

_monitor &
MONITOR_PID=$!

# ─── Keep container alive ─────────────────────────────────────────────────────
# Pod stays up after Claude finishes so humans can exec in and inspect.
tail -f /dev/null &
TAIL_PID=$!

wait ${TAIL_PID}
