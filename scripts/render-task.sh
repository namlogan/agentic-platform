#!/usr/bin/env bash
# Render a GitHub issue into a task file consumable by execute-task.sh.
# Usage: render-task.sh <repo> <issue-number> <worktree> > task.md
#
# Reads AGENT.md from the worktree (if present) to pull in the test command.

set -euo pipefail

REPO="${1:?repo required}"
NUM="${2:?issue number required}"
WORKTREE="${3:?worktree path required}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "render-task: $1 not found" >&2; exit 2; }; }
require gh; require jq

ISSUE=$(gh issue view "$NUM" --repo "$REPO" --json title,body)
TITLE=$(echo "$ISSUE" | jq -r '.title')
BODY=$(echo  "$ISSUE" | jq -r '.body // "(no body)"')

BRANCH=$(cd "$WORKTREE" && git branch --show-current)

# Pull test command from AGENT.md if present.
TEST_CMD="(see AGENT.md)"
if [[ -f "$WORKTREE/AGENT.md" ]]; then
  TEST_CMD=$(grep -i "^test:" "$WORKTREE/AGENT.md" | head -1 | sed 's/^[Tt]est:[[:space:]]*//' || echo "(see AGENT.md)")
fi

cat <<TASK
## Task
${TITLE}

## Spec
${BODY}

## Constraints
- Branch: ${BRANCH} (already checked out)
- Make atomic commits with conventional-commit messages
- All existing tests must pass: \`${TEST_CMD}\`
- Add tests for new behavior
- Do NOT touch files outside the scope listed in the spec
- When finished, print a one-paragraph summary of changes

## Definition of Done
(See acceptance criteria in the Spec section above)
TASK
