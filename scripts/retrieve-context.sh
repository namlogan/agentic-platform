#!/usr/bin/env bash
# retrieve-context.sh — build a compact "RELEVANT EXISTING CODE" pack for the coder.
#
# Combines two local, no-API-cost retrievers, each bounded so a slow/large result can
# never stall the loop or blow up the coder prompt:
#   - Augment Context Engine  (auggie --mcp `codebase-retrieval`, via augment-retrieve.py)
#   - graphify graph query    (when <worktree>/graphify-out/graph.json exists)
#
# Usage:  retrieve-context.sh <worktree> <taskfile>
# stdout: the context pack (possibly empty); exit 0 always — callers degrade gracefully.
set -uo pipefail

WORKTREE="${1:?usage: retrieve-context.sh <worktree> <taskfile>}"
TASKFILE="${2:?usage: retrieve-context.sh <worktree> <taskfile>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

MAX_CHARS="${CONTEXT_MAX_CHARS:-6000}"          # hard cap on the whole pack
AUG_TIMEOUT="${CONTEXT_AUGMENT_TIMEOUT:-45}"    # seconds for augment retrieval
ENABLE_AUGMENT="${CONTEXT_AUGMENT:-1}"
ENABLE_GRAPHIFY="${CONTEXT_GRAPHIFY:-1}"

[ -f "$TASKFILE" ] || exit 0
# Query = the task's title/first non-empty lines (keep it short and specific).
QUERY="$(grep -vE '^\s*$|^#|^=' "$TASKFILE" | head -8 | tr '\n' ' ' | cut -c1-400)"
[ -z "$QUERY" ] && QUERY="$(head -c 400 "$TASKFILE")"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

# ── Augment Context Engine ────────────────────────────────────────────────────
if [ "$ENABLE_AUGMENT" = "1" ] && command -v auggie >/dev/null 2>&1; then
  aug="$(AUGMENT_CWD="$WORKTREE" AUGMENT_TIMEOUT="$AUG_TIMEOUT" \
        python3 "$HERE/augment-retrieve.py" "$QUERY" 2>/dev/null || true)"
  if [ -n "$aug" ]; then
    { echo "### Augment codebase retrieval"; echo "$aug"; echo; } >> "$tmp"
  fi
fi

# ── graphify graph (only if this repo has a graph) ────────────────────────────
if [ "$ENABLE_GRAPHIFY" = "1" ] && command -v graphify >/dev/null 2>&1 \
   && [ -f "$WORKTREE/graphify-out/graph.json" ]; then
  gq="$(cd "$WORKTREE" && graphify query "$QUERY" --budget 800 2>/dev/null || true)"
  if [ -n "$gq" ]; then
    { echo "### graphify graph"; echo "$gq"; echo; } >> "$tmp"
  fi
fi

[ -s "$tmp" ] || exit 0   # nothing retrieved -> emit nothing (coder runs context-free)

{
  echo "=== RELEVANT EXISTING CODE (retrieved; reuse it, do not duplicate) ==="
  head -c "$MAX_CHARS" "$tmp"
  echo
}
