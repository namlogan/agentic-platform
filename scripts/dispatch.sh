#!/usr/bin/env bash
# Poll GitHub for the top-priority agent:ready issue, claim it, and set up a worktree.
# Usage: dispatch.sh <repo> <base-dir>
#   repo      e.g. namlogan/myproject
#   base-dir  e.g. ~/agent-work  (worktrees created as base-dir/<repo>/<issue>)
#
# Outputs on stdout: JSON {"issue":N,"title":"...","repo":"...","worktree":"..."}
# Exit 0 = claimed; exit 1 = nothing to claim; exit 2 = error.

set -euo pipefail

REPO="${1:?repo required (e.g. namlogan/myproject)}"
BASE_DIR="${2:-$HOME/agent-work}"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[dispatch] $*" >&2; }
die()  { log "ERROR: $*"; exit 2; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }
require gh; require git; require jq

# ── find highest-priority agent:ready issue with no unmet deps ──────────────

# Fetch agent:ready issues sorted by priority label (p0 first), then created.
ISSUES=$(gh issue list \
  --repo "$REPO" \
  --label "agent:ready" \
  --json number,title,labels,body \
  --jq 'sort_by(
    (.labels | map(.name) |
      if   contains(["priority:p0"]) then 0
      elif contains(["priority:p1"]) then 1
      else 2 end),
    .number
  )')

if [[ -z "$ISSUES" || "$ISSUES" == "[]" ]]; then
  log "No agent:ready issues found in $REPO."
  exit 1
fi

# Pick the highest-priority issue whose `Depends-on: #a, #b` are all CLOSED
# (a dependency is satisfied once its PR is merged and the issue auto-closes).
NUM=""; TITLE=""
for cand in $(echo "$ISSUES" | jq -r '.[].number'); do
  body=$(echo "$ISSUES" | jq -r ".[] | select(.number==$cand) | .body // \"\"")
  # `|| true`: no Depends-on line means grep exits 1, which under set -e would
  # abort the whole dispatcher — tolerate it (no deps = immediately claimable).
  deps=$(printf '%s' "$body" | grep -ioE 'depends-on:[^\r\n]*' | grep -oE '#[0-9]+' | tr -d '#' | sort -u || true)
  unmet=""
  for d in $deps; do
    state=$(gh issue view "$d" --repo "$REPO" --json state -q .state 2>/dev/null || echo "UNKNOWN")
    [ "$state" = "CLOSED" ] || unmet="$unmet #$d"
  done
  if [ -n "$unmet" ]; then
    log "skip #$cand — waiting on unmet deps:$unmet"
    continue
  fi
  NUM="$cand"
  TITLE=$(echo "$ISSUES" | jq -r ".[] | select(.number==$cand) | .title")
  break
done

if [[ -z "$NUM" ]]; then
  log "No claimable agent:ready issue (all blocked by unmet dependencies)."
  exit 1
fi

SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)
BRANCH="agent/${NUM}-${SLUG}"

log "Claiming issue #${NUM}: ${TITLE}"

# ── check global concurrency cap (max 2 in-flight across all repos) ──────────

WIP_COUNT=$(gh issue list \
  --repo "$REPO" \
  --label "agent:wip" \
  --json number | jq 'length')

if (( WIP_COUNT >= 2 )); then
  log "Global WIP cap reached (${WIP_COUNT} in-flight). Skipping."
  exit 1
fi

# ── claim: swap labels agent:ready → agent:wip ───────────────────────────────

# Side-effect calls must not pollute stdout (it carries the JSON result).
gh issue edit "$NUM" --repo "$REPO" \
  --remove-label "agent:ready" \
  --add-label "agent:wip" >/dev/null

gh issue comment "$NUM" --repo "$REPO" \
  --body "🤖 **Orchestrator claimed** this issue on \`$(hostname)\` at $(date -u +%Y-%m-%dT%H:%M:%SZ). Branch: \`${BRANCH}\`." >/dev/null

# ── set up worktree ───────────────────────────────────────────────────────────

REPO_DIR="$BASE_DIR/$REPO"
WORKTREE="$REPO_DIR/$NUM"
mkdir -p "$REPO_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Cloning $REPO into $REPO_DIR"
  gh repo clone "$REPO" "$REPO_DIR" -- --filter=blob:none
fi

cd "$REPO_DIR"
git fetch origin

# Create worktree on a fresh branch from the default branch.
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')
git worktree prune  # clean up stale entries first
if [[ -d "$WORKTREE" ]]; then
  log "Worktree $WORKTREE already exists, reusing."
elif git branch --list "$BRANCH" | grep -q "$BRANCH"; then
  # branch exists (from a prior interrupted run) but directory is gone — reuse branch
  git worktree add "$WORKTREE" "$BRANCH" >&2
else
  git worktree add -b "$BRANCH" "$WORKTREE" "origin/$DEFAULT" >&2
fi

log "Worktree ready: $WORKTREE  branch: $BRANCH"

jq -n \
  --argjson  number   "$NUM" \
  --arg      title    "$TITLE" \
  --arg      repo     "$REPO" \
  --arg      branch   "$BRANCH" \
  --arg      worktree "$WORKTREE" \
  '{issue: $number, title: $title, repo: $repo, branch: $branch, worktree: $worktree}'
