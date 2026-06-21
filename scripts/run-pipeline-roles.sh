#!/usr/bin/env bash
# run-pipeline-roles.sh — ROLE-SPLIT dispatch driver (next-gen).
#
# Same deterministic outer loop as run-pipeline.sh (claim -> render -> gate ->
# PR/block), but the executor is scripts/execute-roles.sh, which splits the work:
#   REASON  Nex-V2-Pro (-> Claude fallback)   CODE  qwen3-coder (aider)
#   REVIEW  Claude (read-only verdict)         GATE  the repo's real test command
#
# Every state transition stays deterministic bash; the test gate is the final word.
#
# Usage: run-pipeline-roles.sh <owner/repo>[ owner/repo2 ...] [base-dir]
# Exit 0 = handled (or nothing to claim); 2 = setup error.
set -uo pipefail

REPOS="${1:?usage: run-pipeline-roles.sh <owner/repo>[ ...] [base-dir]}"
BASE_DIR="${2:-$HOME/agent-work}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://milai:11434}"

log() { echo "[pipeline-roles] $*" >&2; }
notify() { bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }

# ── 0. SHIP SWEEP — ship any agent:review PR whose CI is now green ────────────
# Runs before claiming new work so each tick advances the loop toward shipping.
# ship.sh self-refuses PRs that aren't green/approved yet; they ship a later tick.
ship_sweep() {
  [ "${AUTO_SHIP:-0}" = "1" ] || return 0
  local r iss pr
  for r in $REPOS; do
    for iss in $(gh issue list --repo "$r" --label agent:review --state open --json number -q '.[].number' 2>/dev/null); do
      pr=$(gh pr list --repo "$r" --state open --json number,headRefName \
            -q "[.[]|select(.headRefName|startswith(\"agent/$iss-\"))][0].number" 2>/dev/null)
      [ -n "$pr" ] && [ "$pr" != "null" ] || continue
      log "ship-sweep: issue #$iss / PR #$pr ($r)"
      log "  $(bash "$HERE/ship.sh" "$r" "$pr" "$iss" "$BASE_DIR/$r/$iss" 2>>"$BASE_DIR/.ship-sweep.log")"
    done
  done
}
ship_sweep

# ── 0b. MILESTONE CHECK — ship the product when a milestone is fully built ────
if [ "${AUTO_SHIP:-0}" = "1" ]; then
  for r in $REPOS; do
    # honour the same per-repo allowlist as ship.sh
    if [ -n "${AUTO_SHIP_REPOS:-}" ]; then case " $AUTO_SHIP_REPOS " in *" $r "*) : ;; *) continue;; esac; fi
    bash "$HERE/milestone-status.sh" "$r" "$BASE_DIR" 2>>"$BASE_DIR/.milestone.log" || true
  done
fi

# ── 1. claim the top-priority agent:ready issue (first repo with work) ───────
REPO=""; CLAIM=""
for r in $REPOS; do
  set +e; out=$(bash "$HERE/dispatch.sh" "$r" "$BASE_DIR"); rc=$?; set -e
  [ "$rc" -eq 1 ] && continue
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then log "dispatch.sh failed for $r (rc=$rc)"; continue; fi
  REPO="$r"; CLAIM="$out"; break
done
[ -z "$REPO" ] && { log "nothing to claim across: $REPOS"; exit 0; }

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
  gh issue comment "$NUM" --repo "$REPO" --body "$(printf '🔴 **Blocked by orchestrator (role-split)** — %s\n\nModel chain: %s\n\nLast log:\n\n```\n%s\n```' "$reason" "${MODEL_CHAIN:-?}" "$(tail -40 "$WORKTREE/.roles-test.log" 2>/dev/null)")" >/dev/null 2>&1 || true
  notify "issue-blocked-$NUM" "🔴 Issue #$NUM blocked: $TITLE
$reason"
}

# ── 2. render the task ───────────────────────────────────────────────────────
bash "$HERE/render-task.sh" "$REPO" "$NUM" "$WORKTREE" > "$WORKTREE/task.md"

# keep scratch files out of git
EXCL=$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)
if [ -n "$EXCL" ]; then mkdir -p "$(dirname "$EXCL")"; printf '%s\n' task.md plan.md '.roles-*' '.aider*' '__pycache__' '.pytest_cache' >> "$EXCL"; fi

# ── 3. role-split execution (reason → code → review → gate) ──────────────────
log "executing role-split flow…"
RESULT=$(bash "$HERE/execute-roles.sh" "$WORKTREE" "$WORKTREE/task.md")
log "executor result: $RESULT"
STATUS=$(echo "$RESULT"      | jq -r '.status')
MODEL_CHAIN=$(echo "$RESULT" | jq -r '.model_chain | join(" → ")')

# audit trail (one JSONL line per build attempt) for cost/throughput review
_AUDIT="${AGENTIC_STATE_DIR:-$HOME/.config/agentic/state}/audit.jsonl"
mkdir -p "$(dirname "$_AUDIT")" 2>/dev/null || true
echo "$RESULT" | jq -c --arg ts "$(date -u +%FT%TZ)" --arg repo "$REPO" --argjson issue "$NUM" \
  '{ts:$ts,repo:$repo,issue:$issue,phase:"build"} + {status,model_chain}' >> "$_AUDIT" 2>/dev/null || true

# ── 4. gate ─────────────────────────────────────────────────────────────────
NEW_COMMITS=$(git -C "$WORKTREE" rev-list --count "origin/$(default_branch)..HEAD" 2>/dev/null || echo 0)
if [ "$STATUS" != "done" ]; then block "executor returned status=$STATUS"; exit 0; fi
if [ "$NEW_COMMITS" -eq 0 ]; then block "tests passed but no commits (nothing to PR)."; exit 0; fi

# ── 5. push + PR + relabel ──────────────────────────────────────────────────
if ! ( cd "$WORKTREE" && git push -u origin "$BRANCH" ) >> "$WORKTREE/.roles-push.log" 2>&1; then
  block "git push failed."; exit 0
fi

{
  echo "Automated by the ROLE-SPLIT pipeline:"
  echo "- Reasoning: Nex-V2-Pro (→ Claude fallback)"
  echo "- Code: qwen3-coder (aider)"
  echo "- Review: Claude (read-only verdict)"
  echo "- Gate: the repo's real test command"
  echo
  echo "Model chain: $MODEL_CHAIN"
  echo
  echo "Closes #$NUM."
  echo; echo "## Task"; echo "$TITLE"
  echo; echo "## Test result (local gate, same command as CI)"
  echo '```'; tail -25 "$WORKTREE/.roles-test.log" 2>/dev/null; echo '```'
} > "$WORKTREE/pr-body.md"

PR_URL=$(cd "$WORKTREE" && gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "agent: $TITLE (#$NUM)" --body-file "$WORKTREE/pr-body.md" 2>&1 | tail -1)
gh issue edit "$NUM" --repo "$REPO" --remove-label agent:wip --add-label agent:review >/dev/null 2>&1 || true
log "PR opened: $PR_URL"
notify "issue-review-$NUM" "✅ Issue #$NUM ready for review: $TITLE
$PR_URL"

echo "{\"issue\":$NUM,\"status\":\"review\",\"pr\":\"$PR_URL\",\"model_chain\":\"$MODEL_CHAIN\"}"
