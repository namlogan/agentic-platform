#!/usr/bin/env bash
# Verify a worktree: run tests in Docker sandbox + LLM review pass.
# Usage: verify.sh <repo> <issue-number> <worktree>
#
# stdout: JSON {"passed":true|false,"gaps":[...],"test_output":"..."}
# exit 0 always (result in JSON)

set -euo pipefail

# Ensure Homebrew and Python user bin are in PATH (non-interactive SSH)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/Library/Python/3.9/bin:$PATH"

REPO="${1:?repo required}"
NUM="${2:?issue number required}"
WORKTREE="${3:?worktree path required}"

log() { echo "[verify] $*" >&2; }
require() { command -v "$1" >/dev/null 2>&1 || { log "$1 not found, skipping"; return 1; }; }

[[ -d "$WORKTREE" ]] || { log "worktree missing: $WORKTREE"; echo '{"passed":false,"gaps":["worktree missing"],"test_output":""}'; exit 0; }

# ── read AGENT.md for test + lint commands ────────────────────────────────────

AGENT_MD="$WORKTREE/AGENT.md"
TEST_CMD=""
LINT_CMD=""
if [[ -f "$AGENT_MD" ]]; then
  TEST_CMD=$(grep -i "^test:"  "$AGENT_MD" | head -1 | sed 's/^[Tt]est:[[:space:]]*//' || true)
  LINT_CMD=$(grep -i "^lint:"  "$AGENT_MD" | head -1 | sed 's/^[Ll]int:[[:space:]]*//' || true)
fi
[[ -z "$TEST_CMD" ]] && TEST_CMD="echo 'No test command in AGENT.md — skipping'"
[[ -z "$LINT_CMD" ]] && LINT_CMD=""

# ── sandboxed test run ────────────────────────────────────────────────────────

TEST_OUTPUT=""
TEST_PASSED=false

run_in_docker() {
  local cmd="$1"
  # Use python:3.11-slim (has pip); install requirements if present before running cmd.
  local setup='if [ -f requirements.txt ]; then pip install -r requirements.txt -q; fi'
  docker run --rm \
    -v "$WORKTREE:/workspace:rw" \
    -w /workspace \
    python:3.11-slim \
    bash -c "${setup} && ${cmd}" 2>&1
}

if require docker; then
  log "Running tests in Docker sandbox…"
  if TEST_OUTPUT=$(run_in_docker "$TEST_CMD" 2>&1); then
    TEST_PASSED=true
    log "Tests passed."
  else
    log "Tests FAILED."
  fi

  if [[ -n "$LINT_CMD" ]]; then
    if LINT_OUTPUT=$(run_in_docker "$LINT_CMD" 2>&1); then
      log "Lint passed."
    else
      log "Lint FAILED."
      TEST_PASSED=false
      TEST_OUTPUT="${TEST_OUTPUT}\n\n--- LINT ---\n${LINT_OUTPUT}"
    fi
  fi
else
  log "Docker not available; running tests directly (unsandboxed)."
  if (cd "$WORKTREE" && eval "$TEST_CMD" > /tmp/verify-test.log 2>&1); then
    TEST_PASSED=true
    TEST_OUTPUT=$(cat /tmp/verify-test.log)
  else
    TEST_OUTPUT=$(cat /tmp/verify-test.log)
    log "Tests FAILED (unsandboxed)."
  fi
fi

# ── LLM review pass ───────────────────────────────────────────────────────────

GAPS=()

VLLM_BASE="${VLLM_BASE:-http://milai:11434/v1}"
VLLM_MODEL="${VLLM_MODEL:-qwen2.5-coder:14b}"

if require curl && require jq; then
  ISSUE_BODY=$(gh issue view "$NUM" --repo "$REPO" --json body -q '.body // ""' 2>/dev/null || true)
  DIFF=$(cd "$WORKTREE" && git diff "origin/$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')"..HEAD -- 2>/dev/null | head -500 || true)

  PROMPT="You are a code reviewer. Given the following issue spec and the git diff, answer with a JSON object: {\"satisfies\": true|false, \"gaps\": [\"...\", ...]}. List each gap as a short imperative sentence. If satisfied, gaps should be empty.\n\n## Issue spec\n${ISSUE_BODY}\n\n## Diff\n\`\`\`diff\n${DIFF}\n\`\`\`"

  LLM_RESP=$(curl -sf "${VLLM_BASE}/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$PROMPT" '{model: "'"$VLLM_MODEL"'", messages: [{role:"user", content: $p}], max_tokens: 512}')" \
    2>/dev/null || true)

  if [[ -n "$LLM_RESP" ]]; then
    REVIEW_JSON=$(echo "$LLM_RESP" | jq -r '.choices[0].message.content' 2>/dev/null || true)
    # Extract JSON object from the response (model may include preamble text).
    REVIEW_JSON=$(echo "$REVIEW_JSON" | grep -o '{.*}' | tail -1 || echo '{}')
    # bash 3.2 compatible (macOS ships without mapfile/readarray)
    while IFS= read -r _gap; do
      [[ -n "$_gap" ]] && GAPS+=("$_gap")
    done < <(echo "$REVIEW_JSON" | jq -r '.gaps[]? // empty' 2>/dev/null || true)
    SATISFIES=$(echo "$REVIEW_JSON" | jq -r '.satisfies // true' 2>/dev/null || echo "true")
    [[ "$SATISFIES" == "false" ]] && TEST_PASSED=false
    log "LLM review: satisfies=${SATISFIES}, gaps=${#GAPS[@]}"
  else
    log "LLM review skipped (vLLM unreachable at ${VLLM_BASE})."
  fi
fi

if (( ${#GAPS[@]} > 0 )); then
  GAPS_JSON=$(printf '%s\n' "${GAPS[@]}" | jq -R . | jq -sc .)
else
  GAPS_JSON='[]'
fi

jq -n \
  --argjson passed      "$( [[ $TEST_PASSED == true ]] && echo true || echo false )" \
  --argjson gaps        "${GAPS_JSON:-[]}" \
  --arg     test_output "$TEST_OUTPUT" \
  '{passed: $passed, gaps: $gaps, test_output: $test_output}'
