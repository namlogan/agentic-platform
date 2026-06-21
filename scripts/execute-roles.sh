#!/usr/bin/env bash
# execute-roles.sh — ROLE-SPLIT executor (the "full flow"):
#
#   REASON  : Nex-V2-Pro (OpenRouter)  ->  fallback Claude (claude -p) if Nex empty
#   CODE    : qwen3-coder-wms via aider (local, free)
#   REVIEW  : Claude (claude -p, read-only verdict)   [auggie pluggable later]
#   GATE    : the repo's real test command (deterministic arbiter)
#
# One reason pass -> code -> review (1 corrective code pass on CHANGES) ->
# test gate (1 corrective code pass on failure). The TEST GATE is the final word.
#
# Usage:  execute-roles.sh <worktree> [taskfile]
# stdout: single JSON line {status, summary, model_chain, files_changed}
# stderr: progress
# exit 0 always (status is in the JSON).
set -uo pipefail

WORKTREE="${1:?usage: execute-roles.sh <worktree> [taskfile]}"
TASKFILE="${2:-$WORKTREE/task.md}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS_ENV="${AGENTIC_MODELS_ENV:-$HOME/.config/agentic/models.env}"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://milai:11434}"
# shellcheck disable=SC1090
[ -f "$MODELS_ENV" ] && source "$MODELS_ENV" || true
# Reviewer's Claude verdict must never edit the tree; only the coder commits.
REVIEW_ENABLED="${REVIEW_ENABLED:-1}"

# CODE backend. Default: qwen3-coder (local, free) as primary coder, with Claude
# Sonnet 4.6 as an escalation tier when qwen can't pass the test gate. Set
# CODER=claude to make Sonnet the PRIMARY coder from attempt 1.
CODER="${CODER:-qwen}"                                # qwen | claude
CODER_CLAUDE_MODEL="${CODER_CLAUDE_MODEL:-claude-sonnet-4-6}"
CODER_ESCALATION="${CODER_ESCALATION:-1}"            # 1 = qwen -> Sonnet on gate failure
CODER_LABEL="qwen"; [ "$CODER" = "claude" ] && CODER_LABEL="sonnet"

log() { echo "[roles] $*" >&2; }
emit() { printf '%s\n' "$1"; }   # final JSON to stdout

[ -f "$TASKFILE" ] || { emit '{"status":"blocked","summary":"no taskfile","model_chain":[],"files_changed":[]}'; exit 0; }
TASK="$(cat "$TASKFILE")"
BASE_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"

# ── test command (same resolution as run-pipeline.sh) ────────────────────────
if [ -f "$WORKTREE/scripts/ci-test.sh" ]; then
  TEST_CMD="bash scripts/ci-test.sh"
elif [ -f "$WORKTREE/AGENT.md" ] && grep -qi '^test:' "$WORKTREE/AGENT.md"; then
  TEST_CMD=$(grep -i '^test:' "$WORKTREE/AGENT.md" | head -1 | sed 's/^[Tt]est:[[:space:]]*//')
else
  TEST_CMD="python3 -m pytest -q"
fi
TEST_CMD="${FORCE_TEST_CMD:-$TEST_CMD}"
log "test command: $TEST_CMD"

# ── conservative scaffold (helps qwen create the right files) ─────────────────
EXISTING_FILES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in docker-compose.yml|AGENT.md|.github/*|infra/*|docs/*|*node_modules*) continue ;; esac
  [ -d "$WORKTREE/${f%%/*}" ] || { [ "${f%%/*}" = "$f" ] || continue; }
  if [ ! -e "$WORKTREE/$f" ]; then
    mkdir -p "$WORKTREE/$(dirname "$f")" 2>/dev/null && : > "$WORKTREE/$f"
  fi
  EXISTING_FILES="$EXISTING_FILES $f"
done <<EOF
$(grep -oE '[A-Za-z0-9_]+(/[A-Za-z0-9_.-]+)*\.(py|ts|tsx|js|jsx|yml|yaml|json|sql|toml|sh)' "$TASKFILE" 2>/dev/null | sort -u | head -20)
EOF
log "scope/scaffold files:${EXISTING_FILES:-<none, repo map>}"

# ── Stage 1: REASON (Nex -> fallback Claude) ─────────────────────────────────
MODEL_CHAIN=""
log "REASON — calling Nex-V2-Pro"
PLAN="$(OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" bash "$HERE/nex-reason.sh" "$TASK" 2>/tmp/nex.err || true)"
if [ -n "$PLAN" ]; then
  MODEL_CHAIN="nex-reason"
else
  log "REASON — Nex empty ($(head -1 /tmp/nex.err 2>/dev/null)); escalating to Claude"
  PLAN="$(claude -p "Produce a concise, concrete implementation plan (files to change, key steps, how to verify) for this task. Do not write full code.

$TASK" 2>/dev/null || true)"
  MODEL_CHAIN="claude-reason"
fi
printf '%s\n' "$PLAN" > "$WORKTREE/plan.md"
log "REASON — plan ready ($(wc -l < "$WORKTREE/plan.md" | tr -d ' ') lines), via $MODEL_CHAIN"

# ── coder: qwen3-coder via aider (default) or Claude Sonnet via `claude -p` ───
DIRECTIVE="IMPORTANT — non-interactive single shot. Implement ALL required changes NOW by
creating/editing files directly. Do NOT ask questions or just describe a plan — write the
full file contents in THIS response."

build_prompt() {  # $1 = extra context (plan or feedback)
  printf '%s\n\n=== IMPLEMENTATION PLAN (from reasoning layer) ===\n%s\n\n=== TASK ===\n%s\n\n%s\n' \
    "$DIRECTIVE" "$PLAN" "$TASK" "$1"
}

code_pass_qwen() {    # $1 = extra context, $2 = logfile  (aider auto-commits)
  local prompt; prompt="$(build_prompt "$1")"
  # shellcheck disable=SC2086
  ( cd "$WORKTREE" && aider --message "$prompt" --yes $EXISTING_FILES ) > "$2" 2>&1 || true
}

code_pass_claude() {  # $1 = extra context, $2 = logfile  (claude -p edits but won't commit)
  local prompt; prompt="$(build_prompt "$1")"
  ( cd "$WORKTREE" && claude -p "$prompt" --model "$CODER_CLAUDE_MODEL" \
      --dangerously-skip-permissions ) > "$2" 2>&1 || true
  if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
    git -C "$WORKTREE" add -A >/dev/null 2>&1 || true
    git -C "$WORKTREE" commit -m "agent($CODER_CLAUDE_MODEL): code pass" >/dev/null 2>&1 || true
  fi
}

code_pass() {  # dispatch to the configured primary coder
  if [ "$CODER" = "claude" ]; then code_pass_claude "$1" "$2"; else code_pass_qwen "$1" "$2"; fi
}

new_commits() { git -C "$WORKTREE" rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo 0; }

log "CODE — attempt 1 ($CODER_LABEL)"
code_pass "" "$WORKTREE/.roles-code-1.log"
MODEL_CHAIN="$MODEL_CHAIN,$CODER_LABEL-code"

# ── Stage 3: REVIEW (Claude verdict, read-only) ──────────────────────────────
review_verdict() {  # echoes verdict text
  local diff
  diff="$(git -C "$WORKTREE" diff "${BASE_SHA}..HEAD" 2>/dev/null; git -C "$WORKTREE" diff 2>/dev/null)"
  [ -z "$diff" ] && { echo "VERDICT: CHANGES
No changes were produced by the coder."; return; }
  claude -p "You are a strict code reviewer. Base your review ONLY on the diff below; do not use any tools or read other files. First line MUST be exactly 'VERDICT: PASS' or 'VERDICT: CHANGES'. If CHANGES, list the specific blocking issues the coder must fix.

=== TASK ===
$TASK

=== PLAN ===
$PLAN

=== DIFF ===
$diff" 2>/dev/null || echo "VERDICT: PASS"
}

if [ "$REVIEW_ENABLED" = "1" ]; then
  log "REVIEW — Claude reviewing the diff"
  VERDICT="$(review_verdict)"
  printf '%s\n' "$VERDICT" > "$WORKTREE/.roles-review-1.log"
  MODEL_CHAIN="$MODEL_CHAIN,claude-review"
  if printf '%s' "$VERDICT" | head -1 | grep -qi 'CHANGES'; then
    log "REVIEW — CHANGES requested; one corrective code pass"
    code_pass "=== CODE REVIEW FEEDBACK (address every point) ===
$VERDICT" "$WORKTREE/.roles-code-2.log"
    MODEL_CHAIN="$MODEL_CHAIN,$CODER_LABEL-fix-review"
  else
    log "REVIEW — PASS"
  fi
fi

# ── Stage 4: TEST GATE (final arbiter; one corrective pass on failure) ───────
run_test() { ( cd "$WORKTREE" && eval "$TEST_CMD" ) > "$WORKTREE/.roles-test.log" 2>&1; }
log "GATE — running tests"
if run_test; then trc=0; else trc=$?; fi
if [ "$trc" -ne 0 ]; then
  log "GATE — failed (rc=$trc); one corrective code pass with test output"
  code_pass "=== TEST OUTPUT (make these pass) ===
$(tail -40 "$WORKTREE/.roles-test.log")" "$WORKTREE/.roles-code-3.log"
  MODEL_CHAIN="$MODEL_CHAIN,$CODER_LABEL-fix-test"
  if run_test; then trc=0; else trc=$?; fi
fi

# ── Stage 4b: CODE ESCALATION to Claude Sonnet when qwen still fails the gate ─
if [ "$trc" -ne 0 ] && [ "$CODER" != "claude" ] && [ "$CODER_ESCALATION" = "1" ] \
   && command -v claude >/dev/null 2>&1; then
  log "GATE — qwen still failing; escalating coder to Claude ($CODER_CLAUDE_MODEL)"
  code_pass_claude "=== qwen3-coder could not make these tests pass; fix the implementation so the test command below passes ===
$(tail -40 "$WORKTREE/.roles-test.log")" "$WORKTREE/.roles-code-4.log"
  MODEL_CHAIN="$MODEL_CHAIN,sonnet-fix-test"
  if run_test; then trc=0; else trc=$?; fi
fi

# ── result ───────────────────────────────────────────────────────────────────
# Real changes = committed (BASE_SHA..HEAD) + any uncommitted, minus scratch/junk.
CHANGED="$(
  { git -C "$WORKTREE" diff --name-only "${BASE_SHA}..HEAD" 2>/dev/null
    git -C "$WORKTREE" status --porcelain 2>/dev/null | awk '{print $2}'; } \
  | grep -v -E '(^|/)(task\.md|plan\.md|__pycache__|\.roles-|\.aider|\.pytest_cache)' \
  | sed '/^$/d' | sort -u | jq -R . | jq -s -c . 2>/dev/null || echo '[]'
)"
COMMITS="$(new_commits)"
CHAIN_JSON="$(printf '%s' "$MODEL_CHAIN" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s -c .)"

if [ "$trc" -eq 0 ] && { [ "$COMMITS" -gt 0 ] 2>/dev/null || [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; }; then
  emit "{\"status\":\"done\",\"summary\":\"tests pass ($MODEL_CHAIN)\",\"model_chain\":$CHAIN_JSON,\"files_changed\":$CHANGED}"
else
  emit "{\"status\":\"blocked\",\"summary\":\"test gate failed (rc=$trc)\",\"model_chain\":$CHAIN_JSON,\"files_changed\":$CHANGED}"
fi
exit 0
