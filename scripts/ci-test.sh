#!/usr/bin/env bash
# CI test runner — reads AGENT.md for the repo's test + lint commands.
# Invoked by .github/workflows/ci.yml on the self-hosted rtx5090 runner.

set -euo pipefail

AGENT_MD="AGENT.md"
if [[ ! -f "$AGENT_MD" ]]; then
  echo "No AGENT.md found — nothing to run." >&2
  exit 0
fi

TEST_CMD=$(grep -i "^test:" "$AGENT_MD" | head -1 | sed 's/^[Tt]est:[[:space:]]*//' || true)
LINT_CMD=$(grep -i "^lint:" "$AGENT_MD" | head -1 | sed 's/^[Ll]int:[[:space:]]*//' || true)

if [[ -n "$TEST_CMD" ]]; then
  echo "=== Running tests: $TEST_CMD ===" >&2
  eval "$TEST_CMD"
fi

if [[ -n "$LINT_CMD" ]]; then
  echo "=== Running lint: $LINT_CMD ===" >&2
  eval "$LINT_CMD"
fi

echo "ci-test: all checks passed."
