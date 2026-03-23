#!/usr/bin/env bash
# implement-tickets.sh
#
# Runs Claude Code on each unimplemented plan ticket in order,
# commits the result, and opens a stacked/chained pull request.
#
# Each PR targets the previous ticket's branch (not main), so they
# can be reviewed in isolation while forming a logical sequence.
# Merge in order: ticket/1.1 → main, then ticket/1.2 (now targets main), etc.
#
# Usage:
#   ./scripts/implement-tickets.sh               # implement the next unimplemented ticket
#   ./scripts/implement-tickets.sh --all         # implement all remaining tickets in sequence
#   ./scripts/implement-tickets.sh --ticket 2.3  # implement a specific ticket
#   ./scripts/implement-tickets.sh --dry-run     # preview what would run without doing it
#   ./scripts/implement-tickets.sh --list        # show ticket status (done/pending)
#
# Requirements:
#   - claude CLI (authenticated)
#   - gh CLI (authenticated, with repo write access)
#   - jq
#   - git (clean working tree before running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_DIR="$REPO_ROOT/plan"
MAIN_BRANCH="main"

PHASE_DIRS=(
  "phase-1-foundation"
  "phase-2-cli"
  "phase-3-queue-and-limits"
  "phase-4-session-management"
  "phase-5-devcontainer-images"
  "phase-6-polish-and-linear"
)

# ── Argument parsing ──────────────────────────────────────────────────────────

MODE="next"       # next | all | specific | list
TARGET_TICKET=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)            MODE="all";                        shift ;;
    --ticket)         MODE="specific"; TARGET_TICKET="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true;                      shift ;;
    --list)           MODE="list";                       shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

# ── Ticket enumeration ────────────────────────────────────────────────────────

# Emit lines of "phase_dir|ticket_json" for every ticket, in order.
all_tickets() {
  for phase_dir in "${PHASE_DIRS[@]}"; do
    local file="$PLAN_DIR/$phase_dir/tickets.json"
    [[ -f "$file" ]] || continue
    while IFS= read -r ticket_json; do
      printf '%s|%s\n' "$phase_dir" "$ticket_json"
    done < <(jq -c '.[]' "$file")
  done
}

# ── Branch and state helpers ──────────────────────────────────────────────────

ticket_branch() {
  echo "ticket/$1"
}

# True if the branch exists locally or on origin.
branch_exists() {
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null ||
    git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$1" &>/dev/null
}

ticket_done() {
  branch_exists "$(ticket_branch "$1")"
}

# Return the branch that the next ticket should target.
# Walks tickets in order and returns the last one whose branch exists,
# stopping at the first gap (to preserve strict ordering).
find_base_branch() {
  local last="$MAIN_BRANCH"
  # Use fd 4 here (fd 3 may be in use by the outer all-tickets loop in --all mode).
  while IFS='|' read -r -u4 _phase ticket_json; do
    local id
    id=$(jq -r '.id' <<< "$ticket_json")
    if ticket_done "$id"; then
      last="$(ticket_branch "$id")"
    else
      break
    fi
  done 4< <(all_tickets)
  echo "$last"
}

# ── Prompt builder ────────────────────────────────────────────────────────────

build_prompt() {
  local phase_dir="$1"
  local ticket_json="$2"

  local id title description labels estimate
  id=$(jq -r '.id'       <<< "$ticket_json")
  title=$(jq -r '.title' <<< "$ticket_json")
  description=$(jq -r '.description' <<< "$ticket_json")
  labels=$(jq -r '.labels | join(", ")' <<< "$ticket_json")
  estimate=$(jq -r '.estimate' <<< "$ticket_json")

  local criteria_lines
  criteria_lines=$(jq -r '.acceptance_criteria[]' <<< "$ticket_json" | \
    awk '{print "- " $0}')

  local files_lines
  files_lines=$(jq -r '.files[]' <<< "$ticket_json" | \
    awk '{print "- " $0}')

  local phase_readme="$PLAN_DIR/$phase_dir/README.md"
  local phase_context=""
  if [[ -f "$phase_readme" ]]; then
    # Include first 150 lines of the phase README for architecture context.
    phase_context=$(head -150 "$phase_readme")
  fi

  cat <<PROMPT
You are implementing a specific ticket for the Autonomous Claude Code Development
Platform project in this repository. The goal is to build infrastructure that
lets Claude Code agents run autonomously on a Kubernetes homelab cluster.

Read CLAUDE.md in the repo root for cluster context before starting.

═══════════════════════════════════════════════════════════════
TICKET ${id}: ${title}
Labels: ${labels}   Estimate: ${estimate}
═══════════════════════════════════════════════════════════════

## Description

${description}

## Files to Create or Modify

${files_lines}

## Acceptance Criteria

Every item below MUST be satisfied before you are done:

${criteria_lines}

═══════════════════════════════════════════════════════════════
PHASE CONTEXT (for architectural reference)
═══════════════════════════════════════════════════════════════

${phase_context}

═══════════════════════════════════════════════════════════════
INSTRUCTIONS
═══════════════════════════════════════════════════════════════

1. Read any existing files relevant to this ticket before writing anything.
2. Implement ONLY what this ticket asks for. Other tickets cover adjacent work.
3. Create every file listed in "Files to Create or Modify".
4. Verify each acceptance criterion is met before finishing.
5. Do NOT create a git commit — the calling script handles that.
6. Do NOT open pull requests or run 'gh' — the calling script handles that.
7. Keep code clean and add comments only where the logic is non-obvious.

When all criteria are satisfied, output one final line:
TICKET COMPLETE: ${id}
PROMPT
}

# ── Claude invocation ─────────────────────────────────────────────────────────

run_claude() {
  local phase_dir="$1"
  local ticket_json="$2"
  local id
  id=$(jq -r '.id' <<< "$ticket_json")

  local prompt
  prompt=$(build_prompt "$phase_dir" "$ticket_json")

  echo ""
  echo "▶ Running Claude Code for ticket $id..."
  echo ""

  if $DRY_RUN; then
    echo "[DRY RUN] Claude prompt (first 30 lines):"
    echo "─────────────────────────────────────────"
    echo "$prompt" | head -30
    echo "─────────────────────────────────────────"
    return 0
  fi

  cd "$REPO_ROOT"
  # --dangerously-skip-permissions: auto-approve tool use (safe in this controlled context)
  # Default output format (text) is used so output is readable in the terminal.
  # </dev/tty: explicitly bind stdin to the terminal so claude doesn't accidentally
  # drain the all_tickets pipe that the outer while-read loop is consuming.
  claude --dangerously-skip-permissions \
         --max-turns 80 \
         -p "$prompt" </dev/tty
}

# ── Git operations ────────────────────────────────────────────────────────────

commit_ticket() {
  local ticket_json="$1"
  local id title
  id=$(jq -r '.id'       <<< "$ticket_json")
  title=$(jq -r '.title' <<< "$ticket_json")

  cd "$REPO_ROOT"

  # Stage everything
  git add -A

  # Check for changes
  if git diff --staged --quiet; then
    echo ""
    echo "⚠  No file changes detected after running Claude on ticket $id."
    echo "   Creating an empty commit to mark the branch and maintain the chain."
    git commit --allow-empty -m "$(cat <<EOF
feat(ticket/$id): $title

No file changes — ticket may already be satisfied by prior work
or Claude completed without writing files. Investigate if unexpected.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
    return 0
  fi

  git commit -m "$(cat <<EOF
feat(ticket/$id): $title

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
}

# ── Pull request creation ─────────────────────────────────────────────────────

create_pr() {
  local ticket_json="$1"
  local base_branch="$2"

  local id title description
  id=$(jq -r '.id'           <<< "$ticket_json")
  title=$(jq -r '.title'     <<< "$ticket_json")
  description=$(jq -r '.description' <<< "$ticket_json")

  local criteria_checklist
  criteria_checklist=$(jq -r '.acceptance_criteria[]' <<< "$ticket_json" | \
    awk '{print "- [ ] " $0}')

  local files_list
  files_list=$(jq -r '.files[]' <<< "$ticket_json" | \
    awk '{print "- `" $0 "`"}')

  # Find the PR URL of the base branch (if it's a ticket branch, not main)
  local base_pr_ref=""
  if [[ "$base_branch" != "$MAIN_BRANCH" ]]; then
    local base_pr_url
    base_pr_url=$(gh pr list --head "$base_branch" --json url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$base_pr_url" ]]; then
      base_pr_ref="**Stacked on:** $base_pr_url"$'\n\n'
    fi
  fi

  local phase_plan_path
  phase_plan_path=$(find "$PLAN_DIR" -name "tickets.json" -exec grep -l "\"$id\"" {} \; | \
    head -1 | sed "s|$REPO_ROOT/||")
  local phase_dir
  phase_dir=$(dirname "$phase_plan_path")

  local pr_body
  pr_body=$(cat <<EOF
${base_pr_ref}## Ticket ${id}: ${title}

${description}

## Files

${files_list}

## Acceptance Criteria

${criteria_checklist}

---

**Phase plan:** [\`${phase_dir}/README.md\`](../${phase_dir}/README.md)
**Base branch:** \`${base_branch}\`
**Chain:** Each ticket in this series targets the previous ticket's branch so changes can be reviewed incrementally. Merge in ticket order.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)

  local pr_url
  pr_url=$(gh pr create \
    --title "ticket ${id}: ${title}" \
    --body "$pr_body" \
    --base "$base_branch")

  echo ""
  echo "✓ PR created: $pr_url"
}

# ── Main ticket implementation flow ───────────────────────────────────────────

implement_ticket() {
  local phase_dir="$1"
  local ticket_json="$2"

  local id
  id=$(jq -r '.id' <<< "$ticket_json")
  local branch
  branch=$(ticket_branch "$id")
  local base_branch
  base_branch=$(find_base_branch)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Ticket : $id — $(jq -r '.title' <<< "$ticket_json")"
  echo "  Branch : $branch"
  echo "  Base   : $base_branch"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if $DRY_RUN; then
    echo ""
    echo "[DRY RUN] Steps that would execute:"
    echo "  1. git fetch origin"
    echo "  2. git checkout -b $branch $base_branch"
    run_claude "$phase_dir" "$ticket_json"
    echo "  3. git add -A && git commit -m 'feat(ticket/$id): ...'"
    echo "  4. git push -u origin $branch"
    echo "  5. gh pr create --base $base_branch --title 'ticket $id: ...'"
    return 0
  fi

  # Sync remotes so branch_exists checks are accurate
  git -C "$REPO_ROOT" fetch origin --quiet

  # Create ticket branch from base
  git -C "$REPO_ROOT" checkout -b "$branch" "$base_branch"

  # Run Claude
  run_claude "$phase_dir" "$ticket_json"

  # Commit
  commit_ticket "$ticket_json"

  # Push branch
  git -C "$REPO_ROOT" push -u origin "$branch"

  # Open PR
  create_pr "$ticket_json" "$base_branch"
}

# ── List mode ─────────────────────────────────────────────────────────────────

list_tickets() {
  git -C "$REPO_ROOT" fetch origin --quiet 2>/dev/null || true

  local done_count=0
  local pending_count=0

  printf '\n%-8s %-6s %s\n' "STATUS" "ID" "TITLE"
  printf '%-8s %-6s %s\n' "------" "----" "-----"

  while IFS='|' read -r -u3 _phase ticket_json; do
    local id title status_str
    id=$(jq -r '.id'       <<< "$ticket_json")
    title=$(jq -r '.title' <<< "$ticket_json")

    if ticket_done "$id"; then
      status_str="done"
      done_count=$((done_count + 1))
    else
      status_str="pending"
      pending_count=$((pending_count + 1))
    fi

    printf '%-8s %-6s %s\n' "$status_str" "$id" "$title"
  done 3< <(all_tickets)

  echo ""
  echo "Done: $done_count   Pending: $pending_count"
  echo ""
}

# ── Preflight checks ──────────────────────────────────────────────────────────

preflight() {
  local ok=true

  if ! command -v claude &>/dev/null; then
    echo "Error: 'claude' CLI not found. Install @anthropic-ai/claude-code."
    ok=false
  fi

  if ! command -v gh &>/dev/null; then
    echo "Error: 'gh' CLI not found. Install the GitHub CLI."
    ok=false
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' not found."
    ok=false
  fi

  if ! git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null; then
    echo "Error: Not inside a git repository."
    ok=false
  fi

  $ok || exit 1

  # Warn on dirty working tree (only block for non-dry-run, non-list modes)
  if [[ "$MODE" != "list" ]] && ! $DRY_RUN; then
    if ! git -C "$REPO_ROOT" diff --quiet || \
       ! git -C "$REPO_ROOT" diff --staged --quiet; then
      echo "Error: Uncommitted changes in the working tree."
      echo "Commit or stash your changes before running implement-tickets."
      exit 1
    fi
  fi
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
  preflight

  case "$MODE" in

    list)
      list_tickets
      ;;

    next)
      local found=false
      while IFS='|' read -r -u3 phase_dir ticket_json; do
        local id
        id=$(jq -r '.id' <<< "$ticket_json")
        if ! ticket_done "$id"; then
          implement_ticket "$phase_dir" "$ticket_json"
          found=true
          break
        fi
      done 3< <(all_tickets)

      if ! $found; then
        echo "All tickets are already implemented."
      fi
      ;;

    all)
      local count=0
      while IFS='|' read -r -u3 phase_dir ticket_json; do
        local id
        id=$(jq -r '.id' <<< "$ticket_json")
        if ! ticket_done "$id"; then
          implement_ticket "$phase_dir" "$ticket_json"
          count=$((count + 1))
        fi
      done 3< <(all_tickets)

      echo ""
      if [[ $count -eq 0 ]]; then
        echo "All tickets are already implemented."
      else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Implemented $count ticket(s)."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      fi
      ;;

    specific)
      local found=false
      while IFS='|' read -r -u3 phase_dir ticket_json; do
        local id
        id=$(jq -r '.id' <<< "$ticket_json")
        if [[ "$id" == "$TARGET_TICKET" ]]; then
          if ticket_done "$id" && ! $DRY_RUN; then
            echo "Ticket $id is already implemented (branch $(ticket_branch "$id") exists)."
            echo "Delete the branch to re-implement it."
            exit 1
          fi
          implement_ticket "$phase_dir" "$ticket_json"
          found=true
          break
        fi
      done 3< <(all_tickets)

      if ! $found; then
        echo "Ticket '$TARGET_TICKET' not found in any phase."
        echo "Run with --list to see all tickets."
        exit 1
      fi
      ;;

  esac
}

main "$@"
