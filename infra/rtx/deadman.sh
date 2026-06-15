#!/usr/bin/env bash
# deadman.sh — cross-machine dead-man switch (Layer 3), runs ON THE RTX server.
#
# The RTX is always-on (inference + CI). On every successful run, M1 pushes a
# heartbeat to ~/.agentic/m1-dispatch-heartbeat here. If that heartbeat goes
# stale, it means M1's whole orchestrator loop (and therefore its own on-box
# watchdog) is down — the one failure the M1 watchdog can never report itself.
# This script notices the silence and sends the alert.
#
# Install on RTX via cron, e.g.:
#   */15 * * * * /home/<user>/agentic/deadman.sh >> ~/.agentic/deadman.log 2>&1
#
# Config on RTX: ~/.agentic/alert.env with TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.
set -u

STATE_DIR="$HOME/.agentic"
CONFIG="$STATE_DIR/alert.env"
HEARTBEAT="$STATE_DIR/m1-dispatch-heartbeat"
MAX_MIN="${DEADMAN_MAX_MIN:-60}"        # M1 dispatch runs every 15 min
STATE="$STATE_DIR/deadman.state"
mkdir -p "$STATE_DIR"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

send() {
  local text="$1"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && { echo "no telegram config"; return; }
  curl -sS --max-time 15 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null 2>&1
}

if [ ! -f "$HEARTBEAT" ]; then
  # No heartbeat yet — M1 may not have run since install. Don't alert on first boot.
  exit 0
fi

age_min=$(( ( $(date +%s) - $(cat "$HEARTBEAT") ) / 60 ))

if [ "$age_min" -gt "$MAX_MIN" ]; then
  if [ ! -f "$STATE" ]; then        # alert once per outage
    send "🔴 DEAD-MAN: M1 orchestrator silent for ${age_min} min (no dispatch heartbeat).
The Mac Mini / Goose loop is likely DOWN. On-box watchdog cannot report this itself."
    touch "$STATE"
  fi
else
  if [ -f "$STATE" ]; then
    send "✅ DEAD-MAN recovered: M1 orchestrator heartbeat is fresh again (${age_min} min)."
    rm -f "$STATE"
  fi
fi
