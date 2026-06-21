#!/usr/bin/env bash
# ship.sh — autonomous SHIP step: gate → merge → deploy → smoke (→ auto-revert).
#
# Closes the loop for human-out-of-the-loop operation. Every guard must pass or
# the PR is left at agent:review (never force-merged).
#
#   GATE   : CI green + Opus merge-review PASS + diff scope ⊆ issue scope +
#            no protected-path changes + not paused + under the daily cap
#   MERGE  : gh pr merge --admin --squash --delete-branch
#   DEPLOY : repo's `ship:` command from AGENT.md (else skip)
#   SMOKE  : repo's `smoke:` command; on failure → revert merge + agent:blocked
#
# Usage:  ship.sh <owner/repo> <pr#> <issue#> <worktree>
# Env (source models.env first): AUTO_SHIP, SHIP_DAILY_CAP, MERGE_REVIEW_MODEL.
# stdout: one JSON line {shipped|refused|reverted, reason}; exit 0 always.
set -uo pipefail

REPO="${1:?usage: ship.sh <repo> <pr#> <issue#> <worktree>}"
PR="${2:?pr number required}"
ISSUE="${3:?issue number required}"
WORKTREE="${4:?worktree required}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$WORKTREE")"
MODELS_ENV="${AGENTIC_MODELS_ENV:-$HOME/.config/agentic/models.env}"
STATE_DIR="${AGENTIC_STATE_DIR:-$HOME/.config/agentic/state}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# shellcheck disable=SC1090
[ -f "$MODELS_ENV" ] && source "$MODELS_ENV" || true
MERGE_REVIEW_MODEL="${MERGE_REVIEW_MODEL:-claude-opus-4-8}"
SHIP_DAILY_CAP="${SHIP_DAILY_CAP:-10}"
SCHEDULER="${SCHEDULER:-com.logan.goose-scheduler}"
mkdir -p "$STATE_DIR"

log()  { echo "[ship] $*" >&2; }
notify(){ bash "$HERE/notify-telegram.sh" "$@" >/dev/null 2>&1 || true; }
emit() {
  printf '%s\n' "$1"
  printf '{"ts":"%s","repo":"%s","issue":%s,"phase":"ship","result":%s}\n' \
    "$(date -u +%FT%TZ)" "$REPO" "$ISSUE" "$1" >> "$STATE_DIR/audit.jsonl" 2>/dev/null || true
  exit 0
}
refuse(){ log "REFUSED: $1"; emit "{\"status\":\"refused\",\"reason\":\"$1\"}"; }

# ── preflight: kill-switch + daily cap ───────────────────────────────────────
[ "${AUTO_SHIP:-0}" = "1" ] || refuse "AUTO_SHIP not enabled"
# Per-repo allowlist: when AUTO_SHIP_REPOS is set, only those repos auto-ship
# (keeps autonomy scoped — e.g. warehouse on, agentic-platform off).
if [ -n "${AUTO_SHIP_REPOS:-}" ]; then
  case " $AUTO_SHIP_REPOS " in *" $REPO "*) : ;; *) refuse "repo not in AUTO_SHIP_REPOS allowlist";; esac
fi
if [ -f "$STATE_DIR/PAUSED" ] || ! launchctl list 2>/dev/null | grep -q "$SCHEDULER"; then
  refuse "pipeline paused (kill-switch active)"
fi
CAP_FILE="$STATE_DIR/ship-$(date +%Y%m%d)"
SHIPPED_TODAY=$(cat "$CAP_FILE" 2>/dev/null || echo 0)
if [ "$SHIPPED_TODAY" -ge "$SHIP_DAILY_CAP" ]; then
  refuse "daily ship cap reached ($SHIPPED_TODAY/$SHIP_DAILY_CAP)"
fi

# ── GATE 1: CI green ─────────────────────────────────────────────────────────
ROLLUP=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  -q '[.statusCheckRollup[]?|.conclusion // .state]|unique|join(",")' 2>/dev/null || echo "")
log "CI rollup: ${ROLLUP:-none}"
case ",$ROLLUP," in
  *",FAILURE,"*|*",ERROR,"*|*",CANCELLED,"*|*",TIMED_OUT,"*|*",PENDING,"*|*",IN_PROGRESS,"*)
    refuse "CI not green ($ROLLUP)";;
esac

# ── GATE 2: protected paths + scope ──────────────────────────────────────────
CHANGED=$(gh pr diff "$PR" --repo "$REPO" --name-only 2>/dev/null || echo "")
[ -n "$CHANGED" ] || refuse "empty or unreadable diff"
while IFS= read -r f; do
  case "$f" in
    .github/workflows/*|infra/*|*.plist|*models.env|*.env|*secrets*|.git/*)
      refuse "diff touches protected path: $f";;
  esac
done <<< "$CHANGED"

# scope ⊆ issue's `### File scope` (if the issue declares one)
SCOPE=$(gh issue view "$ISSUE" --repo "$REPO" --json body -q .body 2>/dev/null \
  | sed -n '/### File scope/,/^###\|^Depends-on:\|^<sub>/p' | grep -oE '`[^`]+`' | tr -d '`' || echo "")
if [ -n "$SCOPE" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    ok=0
    while IFS= read -r s; do [ -z "$s" ] && continue; case "$f" in "$s"|"$s"/*|"${s%/}"/*) ok=1;; esac; done <<< "$SCOPE"
    [ "$ok" = "1" ] || refuse "out-of-scope file changed: $f"
  done <<< "$CHANGED"
  log "scope check passed (${SCOPE//$'\n'/, })"
else
  log "issue declares no file scope; skipping scope check"
fi

# ── GATE 3: Opus merge-review (strict) ───────────────────────────────────────
DIFF=$(gh pr diff "$PR" --repo "$REPO" 2>/dev/null | head -c 16000)
TASK=$(gh issue view "$ISSUE" --repo "$REPO" --json title,body -q '.title+"\n\n"+.body' 2>/dev/null)
_t="$(mktemp -d)"
VERDICT=$(cd "$_t" && claude -p "You are the final MERGE GATE reviewer for an autonomous pipeline that will merge to main with NO human check. Approve ONLY if the diff correctly and safely satisfies the task and is production-safe. First line MUST be exactly 'VERDICT: PASS' or 'VERDICT: CHANGES'.

=== TASK ===
$TASK

=== DIFF ===
$DIFF" --model "$MERGE_REVIEW_MODEL" 2>/dev/null | head -40)
rm -rf "$_t"
if ! printf '%s' "$VERDICT" | head -1 | grep -qi '^VERDICT: PASS'; then
  gh issue comment "$ISSUE" --repo "$REPO" --body "$(printf '🛑 **Merge gate held** by %s:\n\n%s' "$MERGE_REVIEW_MODEL" "$VERDICT")" >/dev/null 2>&1 || true
  notify "ship-hold-$ISSUE" "🛑 PR #$PR held by merge-gate review (issue #$ISSUE)"
  refuse "merge-review not PASS"
fi
log "merge-review PASS"

# ── MERGE ────────────────────────────────────────────────────────────────────
if ! gh pr merge "$PR" --repo "$REPO" --admin --squash --delete-branch >/dev/null 2>&1; then
  refuse "gh pr merge failed"
fi
echo "$((SHIPPED_TODAY+1))" > "$CAP_FILE"
log "merged PR #$PR → main"
notify "ship-merged-$ISSUE" "✅ Merged PR #$PR (issue #$ISSUE) → main"

# refresh main checkout for deploy/smoke
DEFAULT=$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
git -C "$REPO_DIR" fetch origin >/dev/null 2>&1 || true
git -C "$REPO_DIR" checkout "$DEFAULT" >/dev/null 2>&1 || true
git -C "$REPO_DIR" reset --hard "origin/$DEFAULT" >/dev/null 2>&1 || true
MERGE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

agent_cmd() { grep -i "^$1:" "$REPO_DIR/AGENT.md" 2>/dev/null | head -1 | sed "s/^$1:[[:space:]]*//I"; }

# ── DEPLOY (repo `ship:` command, optional) ──────────────────────────────────
SHIP_CMD=$(agent_cmd ship)
if [ -n "$SHIP_CMD" ]; then
  log "DEPLOY — $SHIP_CMD"
  if ! ( cd "$REPO_DIR" && eval "$SHIP_CMD" ) > "$STATE_DIR/ship-deploy.log" 2>&1; then
    notify "ship-deploy-fail-$ISSUE" "⚠️ Deploy failed after merging #$PR (issue #$ISSUE)"
    emit "{\"status\":\"deploy_failed\",\"reason\":\"ship command failed\",\"merge_sha\":\"$MERGE_SHA\"}"
  fi
else
  log "no ship: command in AGENT.md — merge only"
fi

# ── SMOKE (repo `smoke:` command, optional) → auto-revert on failure ──────────
SMOKE_CMD=$(agent_cmd smoke)
if [ -n "$SMOKE_CMD" ]; then
  log "SMOKE — $SMOKE_CMD"
  if ! ( cd "$REPO_DIR" && eval "$SMOKE_CMD" ) > "$STATE_DIR/ship-smoke.log" 2>&1; then
    log "SMOKE failed — reverting merge $MERGE_SHA"
    if ( cd "$REPO_DIR" && git revert --no-edit "$MERGE_SHA" && git push origin "$DEFAULT" ) >/dev/null 2>&1; then
      gh issue edit "$ISSUE" --repo "$REPO" --remove-label agent:review --add-label agent:blocked >/dev/null 2>&1 || true
      gh issue reopen "$ISSUE" --repo "$REPO" >/dev/null 2>&1 || true
      gh issue comment "$ISSUE" --repo "$REPO" --body "$(printf '🔴 **Auto-reverted**: post-merge smoke failed.\n\n```\n%s\n```' "$(tail -30 "$STATE_DIR/ship-smoke.log")")" >/dev/null 2>&1 || true
      notify "ship-revert-$ISSUE" "🔴 Smoke failed for #$PR — reverted main, issue #$ISSUE re-blocked"
      emit "{\"status\":\"reverted\",\"reason\":\"smoke failed\",\"merge_sha\":\"$MERGE_SHA\"}"
    fi
    notify "ship-revert-fail-$ISSUE" "‼️ Smoke failed AND revert failed for #$PR — manual intervention needed"
    emit "{\"status\":\"revert_failed\",\"reason\":\"smoke failed, revert failed\",\"merge_sha\":\"$MERGE_SHA\"}"
  fi
  log "SMOKE passed"
fi

notify "ship-done-$ISSUE" "🚢 Shipped issue #$ISSUE (PR #$PR) — merged + deployed + smoke ok"
emit "{\"status\":\"shipped\",\"pr\":$PR,\"issue\":$ISSUE,\"merge_sha\":\"$MERGE_SHA\"}"
