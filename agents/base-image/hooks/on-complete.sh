#!/usr/bin/env bash
# on-complete.sh — post a completion summary to Linear when Claude finishes a task.
# Called by entrypoint.sh after Claude exits with status=done.
#
# Required env vars:
#   LINEAR_TICKET   — ticket identifier (e.g. LIN-123), or "none" to skip
#   LINEAR_API_KEY  — Linear personal API key
#   GIT_BRANCH      — branch name to include in the comment

set -uo pipefail

EVENTS_LOG=/workspace/.claude-events.log

log_event() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "${EVENTS_LOG}"
}

# Support both LINEAR_TICKET (canonical) and TICKET_ID (legacy fallback)
TICKET="${LINEAR_TICKET:-${TICKET_ID:-none}}"

# Skip silently if no ticket is configured
if [[ -z "${TICKET}" || "${TICKET}" == "none" ]]; then
  exit 0
fi

# Skip gracefully if no API key is available
if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  log_event "LINEAR_COMMENT_FAILED ticket=${TICKET} reason=\"LINEAR_API_KEY not set\""
  exit 0
fi

BRANCH="${GIT_BRANCH:-unknown}"

# Ask Claude to summarize what was just accomplished
SUMMARY=$(claude -p "Summarize in 2-3 sentences what you just accomplished. Be specific about what files were changed, what was added/fixed, and the branch name where the changes are." \
  --max-turns 1 2>/dev/null || true)

if [[ -z "${SUMMARY}" ]]; then
  SUMMARY="Task completed on branch \`${BRANCH}\`."
fi

# Build the Markdown comment body
COMMENT_BODY="**Claude Code agent completed task** on branch \`${BRANCH}\`

${SUMMARY}"

# Resolve the human-readable ticket ID (e.g. LIN-123) to Linear's internal UUID
ISSUE_QUERY=$(printf '{"query":"query { issue(id: \"%s\") { id } }"}' "${TICKET}")

ISSUE_RESPONSE=$(curl -sf -X POST https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${ISSUE_QUERY}" 2>/dev/null || true)

ISSUE_UUID=$(echo "${ISSUE_RESPONSE}" | jq -r '.data.issue.id // ""' 2>/dev/null || true)

if [[ -z "${ISSUE_UUID}" ]]; then
  log_event "LINEAR_COMMENT_FAILED ticket=${TICKET} reason=\"could not resolve issue UUID\""
  exit 0
fi

# Escape body for embedding in JSON
ESCAPED_BODY=$(printf '%s' "${COMMENT_BODY}" | jq -Rs '.')

MUTATION=$(printf '{"query":"mutation { commentCreate(input: { issueId: \"%s\", body: %s }) { success } }"}' \
  "${ISSUE_UUID}" "${ESCAPED_BODY}")

RESPONSE=$(curl -sf -X POST https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${MUTATION}" 2>/dev/null || true)

SUCCESS=$(echo "${RESPONSE}" | jq -r '.data.commentCreate.success // false' 2>/dev/null || echo "false")

if [[ "${SUCCESS}" == "true" ]]; then
  log_event "LINEAR_COMMENT_POSTED ticket=${TICKET} branch=${BRANCH}"
else
  ERROR=$(echo "${RESPONSE}" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null || echo "unknown error")
  log_event "LINEAR_COMMENT_FAILED ticket=${TICKET} reason=\"${ERROR}\""
fi
