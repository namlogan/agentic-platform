#!/usr/bin/env bash
# notify-telegram.sh — single reusable alert channel (Telegram).
#
# Usage:  notify-telegram.sh <key> <message> [recover]
#   <key>      stable id for the alert (e.g. "dispatch-fail", "ollama-down").
#              Used for de-duplication so we don't spam the same alert.
#   <message>  text to send.
#   recover    optional 3rd arg "recover" → always sends (clears dedup state),
#              used to announce an issue is resolved.
#
# Config (NOT committed): create /Users/namto/.config/agentic/alert.env with:
#   TELEGRAM_BOT_TOKEN=123456:ABC...
#   TELEGRAM_CHAT_ID=123456789
# If config is missing, the alert is logged to STATE_DIR/alerts.log and the
# script still exits 0 — so the watchdog keeps working even before Telegram is wired.
#
# De-dup: the same <key> is not re-sent within COOLDOWN seconds (default 4h),
# unless its message text changes or "recover" is passed.
set -u

KEY="${1:?usage: notify-telegram.sh <key> <message> [recover]}"
MSG="${2:?message required}"
MODE="${3:-}"

CONFIG="${AGENTIC_ALERT_ENV:-/Users/namto/.config/agentic/alert.env}"
STATE_DIR="${AGENTIC_STATE_DIR:-/Users/namto/.config/agentic/state}"
COOLDOWN="${ALERT_COOLDOWN:-14400}"   # 4h
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$KEY] $*" >>"$STATE_DIR/alerts.log"; }

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

state_file="$STATE_DIR/last-${KEY}.state"

if [ "$MODE" = "recover" ]; then
  # Only announce recovery if we had previously alerted on this key.
  if [ ! -f "$state_file" ]; then exit 0; fi
  rm -f "$state_file"
else
  # De-dup: skip if same message sent within COOLDOWN.
  if [ -f "$state_file" ]; then
    prev_msg=$(sed -n '2,$p' "$state_file")
    prev_ts=$(sed -n '1p' "$state_file")
    now=$(date +%s)
    if [ "$MSG" = "$prev_msg" ] && [ $((now - prev_ts)) -lt "$COOLDOWN" ]; then
      exit 0
    fi
  fi
  { date +%s; printf '%s' "$MSG"; } >"$state_file"
fi

PREFIX="🤖 agentic-platform"
[ "$MODE" = "recover" ] && PREFIX="✅ agentic-platform (recovered)"
FULL="$PREFIX
$(date '+%Y-%m-%d %H:%M') · $(hostname -s)

$MSG"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  log "NO TELEGRAM CONFIG — would have sent: $MSG"
  echo "notify-telegram: config missing ($CONFIG); logged only" >&2
  exit 0
fi

http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${FULL}" 2>/dev/null)

if [ "$http" = "200" ]; then
  log "sent ok: $MSG"
else
  log "SEND FAILED (http=$http): $MSG"
  echo "notify-telegram: send failed http=$http" >&2
  exit 1
fi
