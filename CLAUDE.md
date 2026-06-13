# Agentic Platform — Claude Context

Design spec: `../agentic-platform-design.md` (full architecture, milestones, appendices)
Status detail: `SETUP-STATUS.md` (last updated 2026-06-12 18:45)

## Hardware

| Machine | Tailscale name | Role |
|---------|---------------|------|
| MacBook Pro M3 | — | Architect console (daily driver) |
| Mac Mini M1 | `mac-mini-ca-namto` | Orchestrator — Goose + dispatcher |
| RTX 5090 server | `milai` / `100.107.129.18` | Inference backend + CI runner |

Network: Tailscale mesh. SSH `ssh milai` from M1. No public ports.

## Inference Stack

**Ollama** (not vLLM — simpler, equivalent for v1) at `http://milai:11434`

| Model | Role | Status |
|-------|------|--------|
| `qwen2.5:7b` | Goose orchestrator brain | Downloaded (as of M1 completion) |
| `qwen2.5-coder:14b` | LLM review in `verify.sh` | ✅ |
| `llama3.2:3b` | Testing only (too small) | ✅ |

Goose config: `~/.config/goose/config.yaml` — provider `ollama`, model `qwen2.5:7b`

## Milestone Status

| Milestone | Status | Notes |
|-----------|--------|-------|
| **M0** Network + inventory | ✅ Complete | Tailscale ✅ · SSH ✅ · `gh auth` ✅ |
| **M1** Inference backend | ✅ Complete | Ollama + 140 tok/s · systemd service |
| **M2** Orchestrator core | ✅ Complete | Goose + aider + qwen2.5-coder:14b · Issue #1 → PR #2 merged 2026-06-13 |
| **M3** Verification & CI | ✅ Complete | `verify.sh` Docker+LLM ✅ · runner `milai-rtx5090` online ✅ · CI pass ✅ |
| **M4** Scheduling & ops | ⏳ Pending | After M3 |
| **M5** Pilot | ⏳ Pending | After M4 |

## Next: M4 — Scheduling & Ops

1. Verify Goose launchd autostart on M1 (survives reboot)
2. Test nightly-report recipe
3. Monitor first unattended overnight dispatch cycle

## Key File Locations

```
agentic-platform/
├── CLAUDE.md                  ← this file
├── SETUP-STATUS.md            ← detailed per-check status
├── recipes/dispatch-issues.yaml
├── recipes/nightly-report.yaml
├── scripts/dispatch.sh
├── scripts/execute-task.sh    ← executor interface (auggie / claude-code / local)
├── scripts/verify.sh
├── scripts/render-task.sh
├── infra/rtx/                 ← vllm.service, runner-setup.sh, docker-compose.yml
├── infra/m1/                  ← launchd plist, goose config template
└── .github/workflows/ci.yml
```

## Quick Commands

```bash
# Check RTX models
ssh milai "ollama list"

# Check Goose
~/.local/bin/goose doctor
~/.local/bin/goose schedule list

# Check runner registration
gh api repos/namlogan/agentic-platform/actions/runners | jq '.runners[]|{name,status}'

# Manual dispatch test
~/.local/bin/goose run --no-session --max-turns 20 \
  --recipe recipes/dispatch-issues.yaml \
  --params REPOS=namlogan/agentic-platform \
  --params BASE_DIR=$HOME/agent-work
```

## Compliance Note

Augment Enterprise account is **company-issued** — confirm AUP before wiring into personal automation. Architecture is executor-agnostic: fallback to `--executor=claude-code` (`claude -p`) or `--executor=local` (Goose on vLLM).

## Repo

`namlogan/agentic-platform` on GitHub (personal account)
