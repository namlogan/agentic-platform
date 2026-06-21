#!/usr/bin/env bash
# plan-product.sh — PLANNER tier: decompose a product brief into a GitHub milestone
# and a dependency-ordered set of agent:ready issues the 24/7 loop can build.
#
# REASONING model: Claude Opus 4.8 (`claude -p`), with a Nex-V2-Pro fallback.
# Output issues carry: spec + Definition of Done + file scope + priority + a
# `Depends-on: #a, #b` line (consumed by dispatch.sh for ordering).
#
# Usage:  plan-product.sh <owner/repo> <brief-file|-> [milestone-title]
#   brief-file "-" reads the brief from stdin.
# Env: source ~/.config/agentic/models.env first (PLANNER_MODEL, OPENROUTER_API_KEY…).
# stdout: created milestone + issue numbers; exit 0 on success, 2 on setup error.
set -uo pipefail

REPO="${1:?usage: plan-product.sh <owner/repo> <brief-file|-> [milestone-title]}"
BRIEF_SRC="${2:?usage: plan-product.sh <owner/repo> <brief-file|-> [milestone-title]}"
MS_TITLE_OVERRIDE="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODELS_ENV="${AGENTIC_MODELS_ENV:-$HOME/.config/agentic/models.env}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# shellcheck disable=SC1090
[ -f "$MODELS_ENV" ] && source "$MODELS_ENV" || true
PLANNER_MODEL="${PLANNER_MODEL:-claude-opus-4-8}"

log() { echo "[planner] $*" >&2; }
die() { log "ERROR: $*"; exit 2; }
command -v gh >/dev/null 2>&1 || die "gh not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

if [ "$BRIEF_SRC" = "-" ]; then BRIEF="$(cat)"; else [ -f "$BRIEF_SRC" ] || die "brief not found: $BRIEF_SRC"; BRIEF="$(cat "$BRIEF_SRC")"; fi
[ -n "${BRIEF// /}" ] || die "empty brief"

PROMPT_SYS="You are the PLANNER/ARCHITECT of an autonomous software factory. Decompose the product brief into a milestone and a set of small, independently-buildable engineering issues that a coding agent can implement and test one at a time.

Output ONLY a single JSON object (no markdown fences, no prose) with EXACTLY this schema:
{
  \"milestone\": {\"title\": str, \"description\": str},
  \"issues\": [
    {\"title\": str,
     \"spec\": str,            // concrete what+how, 3-8 sentences
     \"dod\": str,             // acceptance criteria, testable
     \"scope\": [str],         // file paths this issue may create/edit
     \"priority\": \"p0\"|\"p1\"|\"p2\",
     \"depends_on\": [int]}    // 1-based indices of EARLIER issues only
  ]
}
Rules: order issues topologically (dependencies first); depends_on references only earlier indices; keep each issue small (one branch/PR worth); 4-12 issues; every issue must be testable."

PROMPT="$PROMPT_SYS

=== PRODUCT BRIEF ===
$BRIEF"

# ── call the planner model (Opus primary, Nex fallback) ──────────────────────
RAW=""
if command -v claude >/dev/null 2>&1; then
  log "decomposing with $PLANNER_MODEL"
  # Run from a clean dir so claude -p doesn't load this project's MCP servers/hooks
  # and behave like an agent — we want a single-shot JSON decomposition.
  _tmpd="$(mktemp -d)"
  RAW="$(cd "$_tmpd" && claude -p "$PROMPT" --model "$PLANNER_MODEL" 2>/dev/null || true)"
  rm -rf "$_tmpd"
fi
if [ -z "${RAW// /}" ]; then
  log "planner model empty; falling back to Nex-V2-Pro"
  RAW="$(printf '%s' "$PROMPT" | NEX_TIMEOUT="${NEX_TIMEOUT:-120}" bash "$HERE/nex-reason.sh" 2>/dev/null || true)"
fi
[ -n "${RAW// /}" ] || die "planner produced no output"

# ── create milestone + issues (dependency indices -> real issue numbers) ──────
# RAW goes via env, not stdin: the python heredoc already owns stdin.
export REPO MS_TITLE_OVERRIDE PLANNER_RAW="$RAW"
python3 - <<'PY'
import json, os, re, subprocess, sys

raw = os.environ.get("PLANNER_RAW", "")
# tolerate accidental markdown fences / leading prose: grab the outermost {...}
m = re.search(r'\{.*\}', raw, re.S)
if not m:
    print("[planner] could not find JSON in planner output", file=sys.stderr); sys.exit(2)
try:
    plan = json.loads(m.group(0))
except json.JSONDecodeError as e:
    print(f"[planner] invalid planner JSON: {e}", file=sys.stderr); sys.exit(2)

repo = os.environ["REPO"]
dry = os.environ.get("DRY_RUN") == "1"
issues = plan.get("issues") or []
ms = plan.get("milestone") or {}
ms_title = os.environ.get("MS_TITLE_OVERRIDE") or ms.get("title") or "Autonomous build"
ms_desc = ms.get("description", "")
if not issues:
    print("[planner] no issues in plan", file=sys.stderr); sys.exit(2)

def gh(args, **kw):
    return subprocess.run(["gh", *args], capture_output=True, text=True, **kw)

if dry:
    print(f"[planner] DRY_RUN — would use milestone: {ms_title}", file=sys.stderr)
else:
    # ensure labels exist (no-op if already there)
    for name, color in [("agent:ready","0e8a16"),("priority:p0","b60205"),
                        ("priority:p1","d93f0b"),("priority:p2","fbca04")]:
        gh(["label","create",name,"--repo",repo,"--color",color])
    # ensure milestone exists
    r = gh(["api",f"repos/{repo}/milestones","--jq",".[].title"])
    existing = set(r.stdout.split("\n")) if r.returncode==0 else set()
    if ms_title not in existing:
        gh(["api",f"repos/{repo}/milestones","-f",f"title={ms_title}","-f",f"description={ms_desc}"])
        print(f"[planner] created milestone: {ms_title}", file=sys.stderr)
    else:
        print(f"[planner] reusing milestone: {ms_title}", file=sys.stderr)

created = {}  # 1-based index -> issue number
for i, it in enumerate(issues, start=1):
    title = (it.get("title") or f"Task {i}").strip()
    spec = (it.get("spec") or "").strip()
    dod = (it.get("dod") or "").strip()
    scope = it.get("scope") or []
    prio = it.get("priority") if it.get("priority") in ("p0","p1","p2") else "p1"
    deps = [created[d] for d in (it.get("depends_on") or []) if d in created]

    body = [spec, "", "### Definition of Done", dod, "", "### File scope"]
    body += [f"- `{p}`" for p in scope] or ["- (use your judgement; stay minimal)"]
    if deps:
        body += ["", "Depends-on: " + ", ".join(f"#{n}" for n in deps)]
    body += ["", f"<sub>generated by plan-product.sh — milestone: {ms_title}</sub>"]
    body_txt = "\n".join(body)

    if dry:
        num = 1000 + i  # fake number so dependency rendering is exercised
        created[i] = num
        print(f"#{num}  [{prio}]  {title}" + (f"  (deps: {deps})" if deps else ""))
        print("    body> " + body_txt.replace("\n", "\n    body> "))
        continue

    r = gh(["issue","create","--repo",repo,"--title",title,"--body",body_txt,
            "--label","agent:ready","--label",f"priority:{prio}",
            "--milestone",ms_title])
    if r.returncode != 0:
        print(f"[planner] issue create failed for '{title}': {r.stderr.strip()}", file=sys.stderr)
        continue
    url = r.stdout.strip().splitlines()[-1]
    num = int(re.search(r'/issues/(\d+)', url).group(1))
    created[i] = num
    print(f"#{num}  [{prio}]  {title}" + (f"  (deps: {deps})" if deps else ""))

print(f"[planner] created {len(created)} issues in milestone '{ms_title}'", file=sys.stderr)
PY
