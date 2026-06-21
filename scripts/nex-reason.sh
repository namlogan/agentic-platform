#!/usr/bin/env bash
# nex-reason.sh — call Nex-V2-Pro (nex-agi/nex-n2-pro:free) via OpenRouter for
# REASONING/PLANNING. Project-agnostic. Outputs a step-by-step implementation plan.
#
# Usage:  OPENROUTER_API_KEY=... bash nex-reason.sh "task description"
#    or:  echo "task" | OPENROUTER_API_KEY=... bash nex-reason.sh
# stdout: the plan text (or, on API error, exits non-zero with message on stderr)
set -euo pipefail

API_URL="${NEX_BASE_URL:-https://openrouter.ai/api/v1}/chat/completions"
MODEL_SLUG="${NEX_MODEL:-nex-agi/nex-n2-pro:free}"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "[nex-reason] ERROR: OPENROUTER_API_KEY not set." >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  PROMPT="$*"
elif [ ! -t 0 ]; then
  PROMPT="$(cat)"
else
  echo "Usage: $0 \"task description\"" >&2
  exit 1
fi

export MODEL_SLUG PROMPT
PAYLOAD=$(python3 - << 'PY'
import json, os
payload = {
    "model": os.environ["MODEL_SLUG"],
    "messages": [
        {"role": "system", "content": (
            "You are a senior software architect acting as the REASONING layer of an "
            "autonomous build pipeline. Given a task, produce a concise, concrete, "
            "step-by-step implementation plan: which files to create/edit, the key "
            "functions/changes in each, edge cases, and how to verify. Do NOT write "
            "full code — outline what the coding agent should do. Be specific and short."
        )},
        {"role": "user", "content": os.environ["PROMPT"]},
    ],
    "temperature": 0.3,
    "top_p": 0.9,
}
print(json.dumps(payload))
PY
)

# Bounded: a hung free-tier request must fail fast so the caller can escalate to
# Claude, instead of stalling the live pipeline indefinitely.
response=$(curl -sS --connect-timeout 10 --max-time "${NEX_TIMEOUT:-90}" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" -X POST "${API_URL}" -d "${PAYLOAD}") || {
  echo "[nex-reason] request failed/timed out after ${NEX_TIMEOUT:-90}s" >&2
  exit 1
}

if command -v jq >/dev/null 2>&1; then
  if echo "${response}" | jq -e '.error' >/dev/null 2>&1; then
    echo "[nex-reason] OpenRouter error: $(echo "${response}" | jq -r '.error.message // .error | tostring')" >&2
    exit 1
  fi
  content=$(echo "${response}" | jq -r '.choices[0].message.content // empty')
  [ -n "${content}" ] && echo "${content}" || { echo "[nex-reason] empty content" >&2; exit 1; }
else
  echo "${response}"
fi
