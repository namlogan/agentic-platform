#!/usr/bin/env bash
# Wrapper: activate the AgentScope venv, load model endpoints, run the executor.
# Usage: run-agentscope-executor.sh <worktree> [taskfile]
# stdout: single JSON line (executor contract); stderr: progress.
set -euo pipefail

VENV="${AGENTSCOPE_VENV:-$HOME/.config/agentic/agentscope-venv}"
MODELS_ENV="${AGENTIC_MODELS_ENV:-$HOME/.config/agentic/models.env}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -x "$VENV/bin/python" ] || { echo "[wrapper] venv missing at $VENV" >&2; exit 2; }
# shellcheck disable=SC1090
[ -f "$MODELS_ENV" ] && source "$MODELS_ENV" || echo "[wrapper] no models.env at $MODELS_ENV" >&2

exec "$VENV/bin/python" "$HERE/agentscope_executor.py" "$@"
