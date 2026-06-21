#!/usr/bin/env bash
# milestone-status.sh — "until shipped" check. For each OPEN milestone whose
# issues are all closed (every PR merged), run the product acceptance gate and
# either close+announce the milestone (shipped) or file a follow-up agent:ready
# issue so the loop keeps going.
#
# Usage:  milestone-status.sh <owner/repo> [base-dir]
# Env (source models.env first): runs the repo's `accept:` command from AGENT.md.
# stdout: one line per milestone acted on; exit 0 always.
set -uo pipefail

REPO="${1:?usage: milestone-status.sh <owner/repo> [base-dir]}"
BASE_DIR="${2:-$HOME/agent-work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$BASE_DIR/$REPO"
STATE_DIR="${AGENTIC_STATE_DIR:-$HOME/.config/agentic/state}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$STATE_DIR"

log()  { echo "[milestone] $*" >&2; }
notify(){ bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }
agent_cmd() { grep -i "^$1:" "$REPO_DIR/AGENT.md" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//I"; }

# Milestones that are fully built: no open issues, at least one closed.
COMPLETE=$(gh api "repos/$REPO/milestones?state=open" \
  --jq '.[] | select(.open_issues==0 and .closed_issues>0) | "\(.number)\t\(.title)"' 2>/dev/null || echo "")
[ -n "$COMPLETE" ] || exit 0

while IFS=$'\t' read -r MNUM MTITLE; do
  [ -z "$MNUM" ] && continue
  log "milestone '$MTITLE' (#$MNUM) fully built — running acceptance"

  # refresh main so acceptance runs against shipped code
  if [ -d "$REPO_DIR/.git" ]; then
    DEFAULT=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
    git -C "$REPO_DIR" fetch origin >/dev/null 2>&1 || true
    git -C "$REPO_DIR" checkout "$DEFAULT" >/dev/null 2>&1 || true
    git -C "$REPO_DIR" reset --hard "origin/$DEFAULT" >/dev/null 2>&1 || true
  fi

  ACCEPT_CMD=$(agent_cmd accept)
  ACCEPT_OK=1
  if [ -n "$ACCEPT_CMD" ]; then
    log "ACCEPT — $ACCEPT_CMD"
    ( cd "$REPO_DIR" && eval "$ACCEPT_CMD" ) > "$STATE_DIR/accept-$MNUM.log" 2>&1 || ACCEPT_OK=0
  else
    log "no accept: command in AGENT.md — treating all-merged as shipped"
  fi

  if [ "$ACCEPT_OK" = "1" ]; then
    gh api -X PATCH "repos/$REPO/milestones/$MNUM" -f state=closed >/dev/null 2>&1 || true
    log "SHIPPED '$MTITLE'"
    notify "shipped-$REPO-$MNUM" "🚢 Shipped milestone '$MTITLE' ($REPO) — all issues merged$([ -n "$ACCEPT_CMD" ] && echo ' + acceptance passed')."
    echo "shipped: $MTITLE (#$MNUM)"
  else
    # Acceptance failed → file a follow-up so the loop keeps working the milestone.
    gh issue create --repo "$REPO" --milestone "$MTITLE" \
      --label agent:ready --label priority:p0 \
      --title "agent: fix acceptance failures for '$MTITLE'" \
      --body "$(printf 'The milestone built but the acceptance gate failed. Diagnose and fix.\n\n### Definition of Done\n`%s` passes on the default branch.\n\n### Acceptance output\n```\n%s\n```' "$ACCEPT_CMD" "$(tail -40 "$STATE_DIR/accept-$MNUM.log")")" >/dev/null 2>&1 || true
    notify "accept-fail-$REPO-$MNUM" "🔴 Acceptance failed for '$MTITLE' ($REPO) — filed a p0 fix issue; loop continues."
    echo "accept-failed: $MTITLE (#$MNUM) — follow-up filed"
  fi
done <<< "$COMPLETE"
