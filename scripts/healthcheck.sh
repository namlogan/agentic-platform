#!/usr/bin/env bash
# healthcheck.sh — independent watchdog (Layer 2). Pure bash, NO dependency on
# Goose or Ollama running, so it can still alert when those are the thing that
# broke. Runs every ~15 min via its own launchd job.
#
# Checks (any failing → Telegram alert; clearing → recovery note):
#   1. Ollama reachable on $OLLAMA_HOST and the orchestrator model is present.
#   2. dispatch heartbeat is fresh (job actually completed recently).
#   3. No issue stuck in agent:wip longer than STUCK_MINUTES.
#   4. No issue left in agent:blocked (needs human/triage).
#
# Exit 0 always (it's a monitor); problems are reported via notify-telegram.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENTIC_STATE_DIR:-/Users/namto/.config/agentic/state}"
OLLAMA_HOST="${OLLAMA_HOST:-http://milai:11434}"
MODEL="${GOOSE_MODEL:-qwen3-coder:30b-a3b-q4_K_M}"
PLATFORM_REPO="${PLATFORM_REPO:-namlogan/agentic-platform}"
HEARTBEAT_MAX="${HEARTBEAT_MAX_MIN:-45}"     # dispatch runs every 15 min
STUCK_MINUTES="${STUCK_MINUTES:-90}"
mkdir -p "$STATE_DIR"

notify() { bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }

# 1. Ollama + model -----------------------------------------------------------
tags=$(curl -fsS --max-time 12 "$OLLAMA_HOST/api/tags" 2>/dev/null)
if [ -z "$tags" ]; then
  notify "ollama-down" "🔴 Ollama unreachable at $OLLAMA_HOST (inference backend down)."
elif ! printf '%s' "$tags" | grep -q "$MODEL"; then
  notify "ollama-model" "🔴 Ollama is up but model '$MODEL' is missing at $OLLAMA_HOST.
Available: $(printf '%s' "$tags" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd, -)"
else
  notify "ollama-down" "" recover
  notify "ollama-model" "" recover
fi

# 2. dispatch heartbeat freshness --------------------------------------------
hb="$STATE_DIR/heartbeat-dispatch"
if [ -f "$hb" ]; then
  age_min=$(( ( $(date +%s) - $(cat "$hb") ) / 60 ))
  if [ "$age_min" -gt "$HEARTBEAT_MAX" ]; then
    notify "dispatch-stale" "🟠 No successful dispatch run in ${age_min} min (threshold ${HEARTBEAT_MAX}). Scheduler may be stuck or failing."
  else
    notify "dispatch-stale" "" recover
  fi
fi

# 3 + 4. GitHub queue state ---------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  blocked=$(gh issue list --repo "$PLATFORM_REPO" --label agent:blocked --state open \
            --json number -q 'length' 2>/dev/null || echo "")
  if [ -n "$blocked" ] && [ "$blocked" -gt 0 ]; then
    nums=$(gh issue list --repo "$PLATFORM_REPO" --label agent:blocked --state open \
           --json number -q 'map("#\(.number)")|join(", ")' 2>/dev/null)
    notify "blocked-issues" "🟠 ${blocked} issue(s) in agent:blocked need triage: ${nums}"
  else
    notify "blocked-issues" "" recover
  fi

  # stuck agent:wip older than STUCK_MINUTES
  cutoff=$(( $(date +%s) - STUCK_MINUTES * 60 ))
  stuck=$(gh issue list --repo "$PLATFORM_REPO" --label agent:wip --state open \
          --json number,updatedAt 2>/dev/null \
          | python3 -c "
import json,sys,datetime
cut=$cutoff
try: rows=json.load(sys.stdin)
except Exception: rows=[]
out=[]
for r in rows:
    t=datetime.datetime.fromisoformat(r['updatedAt'].replace('Z','+00:00')).timestamp()
    if t < cut: out.append('#%d' % r['number'])
print(','.join(out))
" 2>/dev/null)
  if [ -n "$stuck" ]; then
    notify "wip-stuck" "🟠 Issue(s) stuck in agent:wip >${STUCK_MINUTES}min: ${stuck}. Likely an orphaned claim — relabel agent:ready to retry."
  else
    notify "wip-stuck" "" recover
  fi
fi

exit 0
