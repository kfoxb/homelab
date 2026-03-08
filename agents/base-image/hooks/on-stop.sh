#!/usr/bin/env bash
# Claude Code Stop hook — secondary rate limit detection.
# Claude invokes this script when it exits, passing JSON context via stdin.
# See: https://docs.anthropic.com/en/docs/claude-code/hooks
#
# We check the transcript/output for rate limit signals as a fallback in case
# the entrypoint's log-based check misses something (e.g. Claude exits before
# flushing the full output).

set -euo pipefail

NAMESPACE="${POD_NAMESPACE:-claude-workers}"

# Read the hook payload from stdin (Claude provides JSON with stop reason, etc.)
HOOK_PAYLOAD=$(cat)

# Extract stop reason if present; Claude may surface "rate_limit" here.
STOP_REASON=$(echo "${HOOK_PAYLOAD}" | jq -r '.stop_reason // ""' 2>/dev/null || true)

RATE_LIMITED=false

# Check stop reason from hook payload
if echo "${STOP_REASON}" | grep -qiE "rate.?limit|usage.?limit|overloaded"; then
  RATE_LIMITED=true
fi

# Also check the output log written by the entrypoint (belt-and-suspenders)
if [[ "${RATE_LIMITED}" == "false" && -f /workspace/.claude-output.log ]]; then
  if grep -qiE "rate.?limit|usage.?limit|too many requests|overloaded" \
      /workspace/.claude-output.log; then
    RATE_LIMITED=true
  fi
fi

if [[ "${RATE_LIMITED}" == "true" ]]; then
  COOLDOWN=$(kubectl get configmap worker-config \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.rateLimitCooldownMinutes}' 2>/dev/null || echo "300")
  RETRY_AFTER=$(date -d "+${COOLDOWN} minutes" +%s)

  echo "on-stop hook: rate limit detected — annotating pod retry-after=${RETRY_AFTER}"

  kubectl annotate pod "${HOSTNAME}" \
    -n "${NAMESPACE}" \
    "ccw/retry-after=${RETRY_AFTER}" \
    --overwrite 2>/dev/null || true

  kubectl label pod "${HOSTNAME}" \
    -n "${NAMESPACE}" \
    "status=rate-limited" \
    --overwrite 2>/dev/null || true
fi
