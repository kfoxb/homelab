#!/usr/bin/env bash
set -euo pipefail

SESSION_ID_FILE=/tmp/claude-session-id
INITIAL_PROMPT_FILE=/tmp/claude-initial-prompt
EVENTS_LOG=/workspace/.claude-events.log

# ─── Event logger ─────────────────────────────────────────────────────────────
log_event() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $@" >> "${EVENTS_LOG}"
}

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
mkdir -p /workspace
log_event "STARTED task=${HOSTNAME} repo=${REPO_URL} branch=${GIT_BRANCH} ticket=${TICKET_ID:-}"

# ─── Clone repo ───────────────────────────────────────────────────────────────
echo "Cloning ${REPO_URL} ..."
CLONE_START=${SECONDS}
git clone "${REPO_URL}" /workspace
cd /workspace
log_event "CLONED repo=${REPO_URL} elapsed=$((SECONDS - CLONE_START))s"

# ─── Checkout / create branch ─────────────────────────────────────────────────
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's|refs/remotes/origin/||' || echo "main")

if git ls-remote --exit-code --heads origin "${GIT_BRANCH}" > /dev/null 2>&1; then
  git checkout "${GIT_BRANCH}"
  git pull --ff-only origin "${GIT_BRANCH}" || true
  log_event "BRANCH_CHECKED_OUT branch=${GIT_BRANCH} created=false"
else
  echo "Branch '${GIT_BRANCH}' not found remotely — creating from '${DEFAULT_BRANCH}'"
  git checkout -b "${GIT_BRANCH}" "origin/${DEFAULT_BRANCH}"
  log_event "BRANCH_CHECKED_OUT branch=${GIT_BRANCH} created=true"
fi

# ─── Write initial CLAUDE.md context if provided ──────────────────────────────
if [[ -n "${CLAUDE_PROMPT_FILE:-}" && -f "${CLAUDE_PROMPT_FILE}" ]]; then
  cp "${CLAUDE_PROMPT_FILE}" /workspace/CLAUDE.md
fi

# ─── Save initial prompt for session resume fallback ──────────────────────────
INITIAL_PROMPT=""
if [[ -n "${CLAUDE_PROMPT_FILE:-}" && -f "${CLAUDE_PROMPT_FILE}" ]]; then
  INITIAL_PROMPT=$(cat "${CLAUDE_PROMPT_FILE}")
fi
printf '%s' "${INITIAL_PROMPT}" > "${INITIAL_PROMPT_FILE}"

# ─── Error handler ────────────────────────────────────────────────────────────
_on_error() {
  local lineno=$1
  log_event "ERROR message=\"unexpected error at line ${lineno}\""
}
trap '_on_error ${LINENO}' ERR

# ─── SIGTERM handler ──────────────────────────────────────────────────────────
_shutdown() {
  echo "SIGTERM received — shutting down Claude gracefully"
  if tmux has-session -t claude 2>/dev/null; then
    tmux send-keys -t claude C-c 2>/dev/null || true
    for i in $(seq 1 25); do
      tmux has-session -t claude 2>/dev/null || break
      sleep 1
    done
    tmux kill-session -t claude 2>/dev/null || true
  fi
  exit 0
}
trap _shutdown SIGTERM

# ─── Start status monitor ─────────────────────────────────────────────────────
/usr/local/bin/status-monitor.sh &
STATUS_MONITOR_PID=$!

# ─── Claude launch script ─────────────────────────────────────────────────────
# Written once; called by each tmux session. Reads the current prompt from a
# control file and uses --resume if a session ID file is present.
cat > /tmp/claude-launch.sh << 'LAUNCHEOF'
#!/usr/bin/env bash
# No set -e here so the exit code below is always reached.
set -o pipefail

SESSION_ID_FILE=/tmp/claude-session-id
PROMPT=$(cat /tmp/claude-current-prompt.txt)

RESUME_ARGS=()
if [[ -f "${SESSION_ID_FILE}" ]]; then
  SESSION_ID=$(cat "${SESSION_ID_FILE}")
  RESUME_ARGS=(--resume "${SESSION_ID}")
fi

# Run Claude, piping output through the session ID extractor then to the log.
# The init event arrives within seconds of startup and contains the session_id.
claude --dangerously-skip-permissions \
  "${RESUME_ARGS[@]}" \
  --output-format stream-json \
  "${PROMPT}" 2>&1 | \
  while IFS= read -r line; do
    if echo "${line}" | jq -e '.subtype == "init"' >/dev/null 2>&1; then
      echo "${line}" | jq -r '.session_id' > "${SESSION_ID_FILE}"
      SID=$(cat "${SESSION_ID_FILE}")
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) CLAUDE_STARTED session_id=${SID}" >> /workspace/.claude-events.log
    fi
    echo "${line}"
  done | tee /workspace/.claude-output.log

# Capture pipeline exit code (claude's exit code with pipefail).
echo $? > /tmp/claude-exit-code
LAUNCHEOF
chmod +x /tmp/claude-launch.sh

# ─── Main work loop ───────────────────────────────────────────────────────────
# Runs Claude, detects rate limits, and resumes after scheduler cooldown.
while true; do
  # Determine whether to resume an existing session or start fresh
  IS_RESUME=false
  if [[ -f "${SESSION_ID_FILE}" ]]; then
    SESSION_ID=$(cat "${SESSION_ID_FILE}")
    printf 'Continue where you left off.' > /tmp/claude-current-prompt.txt
    IS_RESUME=true
    echo "Resuming Claude session ${SESSION_ID}..."
    log_event "RESUMED session_id=${SESSION_ID}"
  else
    cp "${INITIAL_PROMPT_FILE}" /tmp/claude-current-prompt.txt
    echo "Starting Claude Code with initial prompt..."
  fi

  rm -f /tmp/claude-exit-code /tmp/claude-done
  CLAUDE_START=${SECONDS}

  # Start Claude in a tmux session so humans can exec in and observe
  tmux new-session -d -s claude /tmp/claude-launch.sh

  # Wait for the tmux session (and Claude) to exit
  while tmux has-session -t claude 2>/dev/null; do
    sleep 5
  done

  EXIT_CODE=0
  if [[ -f /tmp/claude-exit-code ]]; then
    EXIT_CODE=$(cat /tmp/claude-exit-code)
  fi
  log_event "CLAUDE_DONE exit_code=${EXIT_CODE} elapsed=$((SECONDS - CLAUDE_START))s"

  echo "${EXIT_CODE}" > /tmp/claude-done

  # ── Rate limit detection ────────────────────────────────────────────────────
  RATE_LIMITED=false
  if [[ -f /workspace/.claude-output.log ]]; then
    if grep -qiE "rate.?limit|usage.?limit|too many requests|overloaded" \
        /workspace/.claude-output.log; then
      RATE_LIMITED=true
    fi
  fi

  if [[ "${RATE_LIMITED}" == "true" ]]; then
    COOLDOWN=$(kubectl get configmap worker-config \
      -n "${POD_NAMESPACE:-claude-workers}" \
      -o jsonpath='{.data.rateLimitCooldownMinutes}' 2>/dev/null || echo "300")
    RETRY_AFTER_ISO=$(date -u -d "+${COOLDOWN} minutes" +%Y-%m-%dT%H:%M:%SZ)
    RETRY_AFTER=$(date -d "+${COOLDOWN} minutes" +%s)
    echo "Rate limit hit — annotating pod with retry-after=${RETRY_AFTER}"
    log_event "RATE_LIMITED retry_after=${RETRY_AFTER_ISO}"
    kubectl annotate pod "${HOSTNAME}" \
      -n "${POD_NAMESPACE:-claude-workers}" \
      "ccw/retry-after=${RETRY_AFTER}" \
      --overwrite 2>/dev/null || \
      echo "Warning: could not annotate pod"
    kubectl label pod "${HOSTNAME}" \
      -n "${POD_NAMESPACE:-claude-workers}" \
      "status=rate-limited" \
      --overwrite 2>/dev/null || \
      echo "Warning: could not update pod label"

    # Block until the scheduler resets our label to "running" after cooldown
    echo "Waiting for scheduler to release pod after rate limit cooldown..."
    while true; do
      CURRENT_STATUS=$(kubectl get pod "$HOSTNAME" \
        -n "${POD_NAMESPACE:-claude-workers}" \
        -o jsonpath='{.metadata.labels.status}' 2>/dev/null)
      [ "${CURRENT_STATUS}" = "running" ] && break
      sleep 30
    done
    echo "Re-released by scheduler, resuming work..."
    # Loop back — session ID file is still present so Claude will --resume
    continue

  elif [[ "${EXIT_CODE}" -ne 0 && "${IS_RESUME}" == "true" ]]; then
    # Non-zero exit during a resume attempt likely means invalid/expired session.
    # Fall back to a fresh start with the original prompt.
    echo "Session resume failed (exit ${EXIT_CODE}) — falling back to fresh start"
    rm -f "${SESSION_ID_FILE}"
    kubectl label pod "${HOSTNAME}" \
      -n "${POD_NAMESPACE:-claude-workers}" \
      "status=running" \
      --overwrite 2>/dev/null || true
    continue

  elif [[ "${EXIT_CODE}" -eq 0 ]]; then
    STATUS="done"
  else
    STATUS="error"
  fi

  # ── Follow-up queue: if ccw follow-up wrote a prompt while Claude was running,
  # consume it now and loop back to re-launch Claude with that prompt.
  if [[ -f /tmp/follow-up-queue ]]; then
    FOLLOW_UP_PROMPT=$(cat /tmp/follow-up-queue)
    rm -f /tmp/follow-up-queue
    PREVIEW="${FOLLOW_UP_PROMPT:0:80}"
    log_event "FOLLOW_UP prompt=\"${PREVIEW}\""
    printf '%s' "${FOLLOW_UP_PROMPT}" > /tmp/claude-current-prompt.txt
    kubectl label pod "${HOSTNAME}" \
      -n "${POD_NAMESPACE:-claude-workers}" \
      "status=running" \
      --overwrite 2>/dev/null || true
    continue
  fi

  echo "Claude exited with code ${EXIT_CODE} — updating pod label status=${STATUS}"
  kubectl label pod "${HOSTNAME}" \
    -n "${POD_NAMESPACE:-claude-workers}" \
    "status=${STATUS}" \
    --overwrite 2>/dev/null || \
    echo "Warning: could not update pod label (kubectl may not be available)"

  break
done

# ─── Keep container alive ─────────────────────────────────────────────────────
# Pod stays up after Claude finishes so humans can exec in and inspect.
tail -f /dev/null &
TAIL_PID=$!

wait ${TAIL_PID}
