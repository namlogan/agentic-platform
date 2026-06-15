#!/usr/bin/env bash
# run-job.sh — wrapper that runs a scheduled Goose job and turns its exit
# status into observable signals (heartbeat on success, alert on repeated
# failure). This is what catches the exact failure mode that went silent for
# ~1.5 days: goose exits non-zero (e.g. model 404) and nobody notices.
#
# Usage:  run-job.sh <job-name> -- <command...>
#   <job-name>  e.g. "dispatch" or "nightly"; namespaces heartbeat + fail counter.
#   everything after `--` is the command to run.
#
# On success (exit 0): refresh local heartbeat, push heartbeat to RTX (for the
#   cross-machine dead-man switch), reset the failure counter, send a recovery
#   note if we were previously alerting.
# On failure: increment the failure counter; once it reaches FAIL_THRESHOLD
#   consecutive failures, fire a Telegram alert with the tail of the log.
set -u

JOB="${1:?usage: run-job.sh <job-name> -- <command...>}"; shift
[ "${1:-}" = "--" ] && shift

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENTIC_STATE_DIR:-/Users/namto/.config/agentic/state}"
mkdir -p "$STATE_DIR"
HEARTBEAT="$STATE_DIR/heartbeat-${JOB}"
FAILCOUNT="$STATE_DIR/failcount-${JOB}"
LOGFILE="$STATE_DIR/last-${JOB}.log"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
RTX_HOST="${RTX_SSH_HOST:-milai}"

notify() { bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }

# Run the job, tee output so we can attach a tail to any alert.
set +e
"$@" >"$LOGFILE" 2>&1
rc=$?
set -e 2>/dev/null || true

if [ "$rc" -eq 0 ]; then
  date +%s >"$HEARTBEAT"
  rm -f "$FAILCOUNT"
  # Cross-machine dead-man: let the always-on RTX know M1's loop is alive.
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$RTX_HOST" \
    "mkdir -p ~/.agentic && date +%s > ~/.agentic/m1-${JOB}-heartbeat" >/dev/null 2>&1 || true
  notify "${JOB}-fail" "" recover
  exit 0
fi

# Failure path.
n=0; [ -f "$FAILCOUNT" ] && n=$(cat "$FAILCOUNT" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" >"$FAILCOUNT"

if [ "$n" -ge "$FAIL_THRESHOLD" ]; then
  tail_log=$(tail -n 20 "$LOGFILE" 2>/dev/null)
  notify "${JOB}-fail" "🔴 Job '${JOB}' failed ${n}x in a row (exit ${rc}).

Last log lines:
${tail_log}"
fi
exit "$rc"
