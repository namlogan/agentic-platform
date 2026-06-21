#!/usr/bin/env bash
# nightly-digest.sh — deterministic daily digest (replaces the deprecated goose
# `nightly-report.yaml` recipe, which failed headless with "no text provided for
# prompt"). Summarises queue depth, what merged in the last 24h, blocked issues,
# and ship outcomes; posts a GitHub digest issue + a Telegram note.
#
# Usage:  nightly-digest.sh <owner/repo> [owner/repo2 ...]
# Exit 0 always.
set -uo pipefail

REPOS="${*:-${PLATFORM_REPO:-namlogan/agentic-platform}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENTIC_STATE_DIR:-$HOME/.config/agentic/state}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
notify(){ bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }

YDAY=$(date -v-1d +%F 2>/dev/null || date -d 'yesterday' +%F)
TODAY=$(date +%F)
count(){ gh issue list --repo "$1" --label "$2" --state open --json number -q length 2>/dev/null || echo 0; }

BODY="## 🤖 Daily digest — $TODAY"$'\n'
TG="📊 Nightly digest $TODAY"
for r in $REPOS; do
  rdy=$(count "$r" agent:ready); wip=$(count "$r" agent:wip)
  rev=$(count "$r" agent:review); blk=$(count "$r" agent:blocked)
  merged=$(gh pr list --repo "$r" --state merged --search "merged:>=$YDAY" --json number,title \
            -q '.[] | "  - #\(.number) \(.title)"' 2>/dev/null || echo "")
  nmerged=$(printf '%s\n' "$merged" | grep -c '^  - ' || true)
  BODY+=$'\n'"### $r"$'\n'
  BODY+="- Queue: ready **$rdy** · wip **$wip** · review **$rev** · blocked **$blk**"$'\n'
  BODY+="- Merged in last 24h: **$nmerged**"$'\n'
  [ -n "$merged" ] && BODY+="$merged"$'\n'
  TG+=$'\n'"$r: ready $rdy · wip $wip · review $rev · blocked $blk · merged24h $nmerged"
done

# ship outcomes today (from the audit trail, if present)
if [ -f "$STATE_DIR/audit.jsonl" ]; then
  ships=$(grep "\"$TODAY" "$STATE_DIR/audit.jsonl" 2>/dev/null | grep '"phase":"ship"' \
          | jq -r '.result.status' 2>/dev/null | sort | uniq -c | tr '\n' ' ' || echo "")
  [ -n "$ships" ] && { BODY+=$'\n'"### Ship outcomes today"$'\n'"\`$ships\`"$'\n'; TG+=$'\n'"ships: $ships"; }
fi

if [ "${NIGHTLY_DRYRUN:-0}" = "1" ]; then
  printf '%s\n' "$BODY"; echo "--- telegram ---"; printf '%s\n' "$TG"; exit 0
fi

FIRST_REPO="${REPOS%% *}"
gh issue create --repo "$FIRST_REPO" --title "🤖 Daily digest — $TODAY" --body "$BODY" >/dev/null 2>&1 \
  && echo "[nightly] digest issue posted to $FIRST_REPO" >&2
notify "nightly-$TODAY" "$TG"
echo "[nightly] done" >&2
