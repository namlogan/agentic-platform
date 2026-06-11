#!/usr/bin/env bash
# Executor interface — runs a task file inside a worktree and returns JSON.
# Usage: execute-task.sh [--executor=auggie|claude-code|local] <worktree> <taskfile>
#
# stdout: {"status":"done|failed|blocked","summary":"...","files_changed":[...]}
# stderr: progress/log lines
# exit 0 always (status is in the JSON)

set -euo pipefail

EXECUTOR="auggie"
for arg in "$@"; do
  case $arg in
    --executor=*) EXECUTOR="${arg#*=}"; shift ;;
  esac
done

WORKTREE="${1:?worktree path required}"
TASKFILE="${2:?task file path required}"

log()  { echo "[execute-task/${EXECUTOR}] $*" >&2; }
die()  { log "FATAL: $*"; exit 2; }

[[ -d "$WORKTREE" ]] || die "worktree does not exist: $WORKTREE"
[[ -f "$TASKFILE" ]] || die "task file does not exist: $TASKFILE"

MAX_ATTEMPTS=2
TIMEOUT=1800  # 30 min per attempt

run_attempt() {
  local attempt="$1"
  local result_log="$WORKTREE/.agent-result-${attempt}.log"
  log "Attempt ${attempt}/${MAX_ATTEMPTS}"

  case "$EXECUTOR" in

    auggie)
      (cd "$WORKTREE" && timeout "$TIMEOUT" auggie --print --quiet "$(cat "$TASKFILE")") \
        > "$result_log" 2>&1
      ;;

    claude-code)
      (cd "$WORKTREE" && timeout "$TIMEOUT" claude -p "$(cat "$TASKFILE")") \
        > "$result_log" 2>&1
      ;;

    local)
      # Goose subagent on local vLLM — reads GOOSE_PROVIDER from env.
      (cd "$WORKTREE" && timeout "$TIMEOUT" goose run --no-session --instructions "$(cat "$TASKFILE")") \
        > "$result_log" 2>&1
      ;;

    *)
      die "Unknown executor: $EXECUTOR"
      ;;
  esac

  echo "$result_log"
}

STATUS="failed"
SUMMARY=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  result_log=$(run_attempt "$attempt" 2>&1) || true
  actual_log="$WORKTREE/.agent-result-${attempt}.log"

  if [[ -f "$actual_log" ]]; then
    # Extract last paragraph as summary (executor prints summary at end per task template).
    SUMMARY=$(tail -20 "$actual_log" | awk '/^$/{p=""} /^./{p=p" "$0} END{print p}' | xargs)
    [[ -z "$SUMMARY" ]] && SUMMARY=$(tail -3 "$actual_log" | tr '\n' ' ')
  fi

  # Detect success: check if the branch has new commits.
  NEW_COMMITS=$(cd "$WORKTREE" && git log "origin/$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')"..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
  if (( NEW_COMMITS > 0 )); then
    STATUS="done"
    break
  fi

  log "Attempt ${attempt} produced no commits. $(( MAX_ATTEMPTS - attempt )) retries left."
  [[ $attempt -lt $MAX_ATTEMPTS ]] || STATUS="blocked"
done

FILES_CHANGED=$(cd "$WORKTREE" && git diff --name-only "origin/$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')"..HEAD 2>/dev/null | jq -R . | jq -sc .)

jq -n \
  --arg status        "$STATUS" \
  --arg summary       "${SUMMARY:-no summary}" \
  --argjson files     "${FILES_CHANGED:-[]}" \
  '{status: $status, summary: $summary, files_changed: $files}'
