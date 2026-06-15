#!/usr/bin/env bash
# run-pipeline.sh — DETERMINISTIC dispatch driver.
#
# Replaces the LLM-orchestrated Goose recipe with a bash state machine. The LLM
# (qwen3-coder via aider) is used ONLY to write code; every state transition
# (claim, test gate, retry, relabel, PR/block) is deterministic bash — so the
# pipeline can't "derail" the way an LLM walking an 8-step procedure does.
#
# Flow: claim agent:ready issue -> render task -> aider implements -> run the
# repo's real test command -> on failure, ONE corrective aider run with the test
# output -> still failing => agent:blocked + log + Telegram; passing => push + PR
# + agent:review.
#
# Usage: run-pipeline.sh <owner/repo> [base-dir]
# Exit 0 = handled (claimed+processed, or nothing to claim); 2 = setup error.
set -uo pipefail

REPOS="${1:?usage: run-pipeline.sh <owner/repo>[ owner/repo2 ...] [base-dir]}"
BASE_DIR="${2:-$HOME/agent-work}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://milai:11434}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"

log() { echo "[pipeline] $*" >&2; }
notify() { bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }

# ── 1. claim the top-priority agent:ready issue (first repo with work) ───────
REPO=""
CLAIM=""
for r in $REPOS; do
  set +e
  out=$(bash "$HERE/dispatch.sh" "$r" "$BASE_DIR")
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then continue; fi               # nothing ready in this repo
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then log "dispatch.sh failed for $r (rc=$rc)"; continue; fi
  REPO="$r"; CLAIM="$out"; break
done
if [ -z "$REPO" ]; then log "nothing to claim across: $REPOS"; exit 0; fi

# Robustly isolate the JSON result (ignore any stray stdout before it).
CLAIM=$(printf '%s\n' "$CLAIM" | awk '/^\{/{f=1} f')

NUM=$(echo "$CLAIM"      | jq -r '.issue')
TITLE=$(echo "$CLAIM"    | jq -r '.title')
BRANCH=$(echo "$CLAIM"   | jq -r '.branch')
WORKTREE=$(echo "$CLAIM" | jq -r '.worktree')
log "claimed #$NUM ($TITLE) → $WORKTREE"

default_branch() { git -C "$WORKTREE" symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||'; }

block() {
  local reason="$1"
  log "BLOCKED: $reason"
  gh issue edit "$NUM" --repo "$REPO" --remove-label agent:wip --add-label agent:blocked >/dev/null 2>&1 || true
  gh issue comment "$NUM" --repo "$REPO" --body "$(printf '🔴 **Blocked by orchestrator** — %s\n\nLast log:\n\n```\n%s\n```' "$reason" "$(tail -40 "$WORKTREE/.pipeline.log" 2>/dev/null)")" >/dev/null 2>&1 || true
  notify "issue-blocked-$NUM" "🔴 Issue #$NUM blocked: $TITLE
$reason"
}

# ── 2. render the task ───────────────────────────────────────────────────────
bash "$HERE/render-task.sh" "$REPO" "$NUM" "$WORKTREE" > "$WORKTREE/task.md"

# Files in scope (from the issue's "File scope" bullets) — passed to aider so a
# small model edits the right files instead of guessing via repo map.
SCOPE_FILES=$(awk '
  tolower($0) ~ /file scope/ {f=1; next}
  f && /^[[:space:]]*[-*]/ {gsub(/^[[:space:]]*[-*][[:space:]]*/,""); gsub(/`/,""); print; next}
  f && /^#/ {f=0}
' "$WORKTREE/task.md" | tr -d ' ')
EXISTING_FILES=""
for fpath in $SCOPE_FILES; do
  [ -e "$WORKTREE/$fpath" ] && EXISTING_FILES="$EXISTING_FILES $fpath" || EXISTING_FILES="$EXISTING_FILES $fpath"
done
log "scope files: ${EXISTING_FILES:-<none, aider will use repo map>}"

# Test command: prefer the repo's ci-test.sh (identical to CI), else AGENT.md.
if [ -f "$WORKTREE/scripts/ci-test.sh" ]; then
  TEST_CMD="bash scripts/ci-test.sh"
elif [ -f "$WORKTREE/AGENT.md" ] && grep -qi '^test:' "$WORKTREE/AGENT.md"; then
  TEST_CMD=$(grep -i '^test:' "$WORKTREE/AGENT.md" | head -1 | sed 's/^[Tt]est:[[:space:]]*//')
else
  TEST_CMD="python3 -m pytest -q"
fi
# Ops/acceptance hook: FORCE_TEST_CMD overrides the gate (e.g. FORCE_TEST_CMD=false
# to deterministically exercise the blocked path). NEVER set in production.
TEST_CMD="${FORCE_TEST_CMD:-$TEST_CMD}"
log "test command: $TEST_CMD"

# ── 3. implement + test, with one corrective retry ───────────────────────────
PROMPT="$(cat "$WORKTREE/task.md")"
: > "$WORKTREE/.pipeline.log"
STATUS="failed"
for a in $(seq 1 "$MAX_ATTEMPTS"); do
  log "attempt $a/$MAX_ATTEMPTS — aider implementing"
  # shellcheck disable=SC2086
  ( cd "$WORKTREE" && aider --message "$PROMPT" --yes $EXISTING_FILES ) \
    > "$WORKTREE/.aider-$a.log" 2>&1 || true
  cat "$WORKTREE/.aider-$a.log" >> "$WORKTREE/.pipeline.log"

  log "attempt $a — running tests"
  if ( cd "$WORKTREE" && eval "$TEST_CMD" ) > "$WORKTREE/.test-$a.log" 2>&1; then
    cat "$WORKTREE/.test-$a.log" >> "$WORKTREE/.pipeline.log"
    STATUS="done"; log "attempt $a — tests PASSED"; break
  fi
  cat "$WORKTREE/.test-$a.log" >> "$WORKTREE/.pipeline.log"
  log "attempt $a — tests FAILED"
  PROMPT="The previous attempt did not pass the tests. Fix the code so ALL tests pass.

=== Test output ===
$(tail -40 "$WORKTREE/.test-$a.log")

=== Original task ===
$(cat "$WORKTREE/task.md")"
done

# ── 4. gate on commits + test status ─────────────────────────────────────────
NEW_COMMITS=$(git -C "$WORKTREE" rev-list --count "origin/$(default_branch)..HEAD" 2>/dev/null || echo 0)
if [ "$STATUS" != "done" ]; then
  block "tests did not pass after $MAX_ATTEMPTS attempts."
  exit 0
fi
if [ "$NEW_COMMITS" -eq 0 ]; then
  block "tests passed but the executor produced no commits (nothing to PR)."
  exit 0
fi

# ── 5. push + open PR + relabel agent:review ─────────────────────────────────
if ! ( cd "$WORKTREE" && git push -u origin "$BRANCH" ) >> "$WORKTREE/.pipeline.log" 2>&1; then
  block "git push failed."
  exit 0
fi

{
  echo "Automated by qwen3-coder (aider) via the deterministic dispatch driver."
  echo "Closes #$NUM."
  echo
  echo "## Task"
  echo "$TITLE"
  echo
  echo "## Test result (local gate, same command as CI)"
  echo '```'
  tail -25 "$WORKTREE"/.test-*.log 2>/dev/null | tail -25
  echo '```'
} > "$WORKTREE/pr-body.md"

PR_URL=$(cd "$WORKTREE" && gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "agent: $TITLE (#$NUM)" --body-file "$WORKTREE/pr-body.md" 2>&1 | tail -1)
gh issue edit "$NUM" --repo "$REPO" --remove-label agent:wip --add-label agent:review >/dev/null 2>&1 || true
log "PR opened: $PR_URL"
notify "issue-review-$NUM" "✅ Issue #$NUM ready for review: $TITLE
$PR_URL" recover 2>/dev/null || bash "$HERE/notify-telegram.sh" "issue-review-$NUM" "✅ Issue #$NUM → review: $TITLE
$PR_URL" >/dev/null 2>&1 || true

echo "{\"issue\":$NUM,\"status\":\"review\",\"pr\":\"$PR_URL\"}"
