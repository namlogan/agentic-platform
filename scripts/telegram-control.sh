#!/usr/bin/env bash
# telegram-control.sh — two-way Telegram control for the agentic pipeline.
#
# Long-polls Telegram getUpdates and acts ONLY on messages from the authorized
# chat_id (TELEGRAM_CHAT_ID in alert.env). Lets Logan drive the pipeline from
# his phone.
#
# Commands:
#   /status        pipeline state (queue counts, heartbeat, ollama, scheduler)
#   /dispatch      run a dispatch pass right now
#   /retry N       move issue #N back to agent:ready
#   /pause /resume kill switch (unload/load the scheduler)
#   /help
#   <free text>    create an agent:ready GitHub issue from the message
#
# Runs as a KeepAlive LaunchAgent. Test one command without the loop:
#   telegram-control.sh --handle "/status"
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${AGENTIC_ALERT_ENV:-$HOME/.config/agentic/alert.env}"
STATE_DIR="${AGENTIC_STATE_DIR:-$HOME/.config/agentic/state}"
PLATFORM_REPO="${PLATFORM_REPO:-namlogan/agentic-platform}"
OLLAMA_HOST="${OLLAMA_HOST:-http://milai:11434}"
SCHEDULER="com.logan.goose-scheduler"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$STATE_DIR"
OFFSET_FILE="$STATE_DIR/tg-offset"

# shellcheck source=/dev/null
. "$CONFIG" 2>/dev/null || { echo "telegram-control: no $CONFIG"; exit 1; }
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && { echo "telegram-control: token/chat_id missing"; exit 1; }
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

send() {
  curl -sS --max-time 15 "$API/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

handle() {
  local text="$1"
  case "$text" in
    /help|/start)
      send "🤖 Agentic control
/status — trạng thái pipeline
/dispatch — chạy dispatch ngay
/retry N — đưa issue #N về agent:ready
/pause — dừng scheduler (kill switch)
/resume — bật lại scheduler
/build <brief> — phân rã 1 brief sản phẩm thành milestone + nhiều issue
/progress — tiến độ milestone (burndown)
Hoặc nhắn mô tả 1 task → mình tạo issue agent:ready để pipeline làm."
      ;;
    /progress)
      local prog
      prog="$(gh api "repos/$PLATFORM_REPO/milestones?state=open" \
        --jq '.[] | "• \(.title): \(.closed_issues)/\(.closed_issues+.open_issues) merged"' 2>/dev/null)"
      [ -z "$prog" ] && prog="(không có milestone đang mở)"
      send "🏭 Tiến độ milestone ($PLATFORM_REPO)
$prog"
      ;;
    /build\ *)
      local brief heredir created
      brief="${text#/build }"
      send "🧠 Đang phân rã brief thành milestone + issues (Opus)…"
      heredir="$(cd "$(dirname "$0")" && pwd)"
      created=$(printf '%s' "$brief" | bash "$heredir/plan-product.sh" "$PLATFORM_REPO" - 2>/dev/null | grep -cE '^#[0-9]+')
      if [ "${created:-0}" -gt 0 ]; then
        send "🏭 Đã tạo ${created} issue agent:ready từ brief. Pipeline sẽ tự build theo thứ tự phụ thuộc (/status để theo dõi)."
      else
        send "⚠️ Planner không tạo được issue nào. Kiểm tra brief hoặc log planner."
      fi
      ;;
    /status)
      local rdy wip rev blk age ol sched
      rdy=$(gh issue list --repo "$PLATFORM_REPO" --label agent:ready  --state open --json number -q length 2>/dev/null)
      wip=$(gh issue list --repo "$PLATFORM_REPO" --label agent:wip    --state open --json number -q length 2>/dev/null)
      rev=$(gh issue list --repo "$PLATFORM_REPO" --label agent:review --state open --json number -q length 2>/dev/null)
      blk=$(gh issue list --repo "$PLATFORM_REPO" --label agent:blocked --state open --json number -q length 2>/dev/null)
      if [ -f "$STATE_DIR/heartbeat-dispatch" ]; then
        age="$(( ( $(date +%s) - $(cat "$STATE_DIR/heartbeat-dispatch") ) / 60 )) phút trước"
      else age="n/a"; fi
      curl -fsS --max-time 8 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && ol="up" || ol="DOWN"
      launchctl list | grep -q "$SCHEDULER" && sched="loaded" || sched="STOPPED"
      send "📊 Pipeline status
ready: ${rdy:-?} · wip: ${wip:-?} · review: ${rev:-?} · blocked: ${blk:-?}
dispatch gần nhất: ${age}
ollama: ${ol} · scheduler: ${sched}"
      ;;
    /dispatch)
      launchctl kickstart -k "gui/$(id -u)/$SCHEDULER" >/dev/null 2>&1
      send "▶️ Đã kích hoạt dispatch ngay bây giờ."
      ;;
    /pause)
      launchctl unload "$HOME/Library/LaunchAgents/$SCHEDULER.plist" >/dev/null 2>&1
      send "⏸️ Scheduler đã DỪNG (kill switch). Gõ /resume để bật lại."
      ;;
    /resume)
      launchctl load "$HOME/Library/LaunchAgents/$SCHEDULER.plist" >/dev/null 2>&1
      send "▶️ Scheduler đã bật lại."
      ;;
    /retry\ *)
      local n="${text#/retry }"; n="$(printf '%s' "$n" | tr -cd '0-9')"
      if [ -n "$n" ]; then
        gh issue edit "$n" --repo "$PLATFORM_REPO" \
          --remove-label agent:blocked --remove-label agent:wip --add-label agent:ready >/dev/null 2>&1
        send "🔄 Issue #${n} → agent:ready (sẽ làm lại ở lượt dispatch tới; /dispatch để chạy ngay)."
      else send "Cú pháp: /retry <số issue>"; fi
      ;;
    /*)
      send "Lệnh không rõ. /help để xem danh sách."
      ;;
    *)
      # Guard: ignore trivially short / acknowledgement messages so casual chat
      # ("ok", "thanks") doesn't get turned into issues.
      local clean; clean="$(printf '%s' "$text" | tr -d '[:space:]')"
      if [ "${#clean}" -lt 12 ]; then
        send "ℹ️ Tin hơi ngắn nên mình không tạo issue. Mô tả task cụ thể hơn (≥12 ký tự), hoặc /help để xem lệnh."
        return
      fi
      local title out url
      title="$(printf '%s' "$text" | head -1 | cut -c1-70)"
      out=$(gh issue create --repo "$PLATFORM_REPO" --label agent:ready \
        --title "agent: $title" \
        --body "$(printf '%s\n\n_Tạo từ Telegram._' "$text")" 2>&1)
      url=$(printf '%s' "$out" | grep -o 'https://github.com[^ ]*' | head -1)
      if [ -n "$url" ]; then
        send "✅ Đã tạo issue agent:ready:
$url
Pipeline sẽ nhận ở lượt dispatch tới (/dispatch để chạy ngay)."
      else
        send "⚠️ Tạo issue lỗi: $(printf '%s' "$out" | tail -1)"
      fi
      ;;
  esac
}

# Test hook: handle one message without entering the poll loop.
if [ "${1:-}" = "--handle" ]; then handle "${2:?text required}"; exit 0; fi

# Cold start: baseline the offset to the latest update so old/backlog messages
# aren't replayed as commands.
offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo "")
if [ -z "$offset" ]; then
  init=$(curl -sS --max-time 30 "$API/getUpdates?timeout=0" 2>/dev/null || echo "")
  offset=$(printf '%s' "$init" | jq -r '.result[-1].update_id // 0' 2>/dev/null || echo 0)
  echo "$offset" >"$OFFSET_FILE"
fi

echo "telegram-control: listening (offset=$offset)"
while true; do
  resp=$(curl -sS --max-time 60 "$API/getUpdates?timeout=25&offset=$((offset + 1))" 2>/dev/null) || { sleep 5; continue; }
  count=$(printf '%s' "$resp" | jq '.result | length' 2>/dev/null || echo 0)
  [ -z "$count" ] && count=0
  i=0
  while [ "$i" -lt "$count" ]; do
    upd=$(printf '%s' "$resp" | jq -c ".result[$i]")
    uid=$(printf '%s' "$upd" | jq -r '.update_id')
    cid=$(printf '%s' "$upd" | jq -r '.message.chat.id // empty')
    txt=$(printf '%s' "$upd" | jq -r '.message.text // empty')
    offset="$uid"; echo "$offset" >"$OFFSET_FILE"
    if [ "$cid" = "$TELEGRAM_CHAT_ID" ] && [ -n "$txt" ]; then
      echo "telegram-control: cmd from authorized: $txt"
      handle "$txt"
    fi
    i=$((i + 1))
  done
done
