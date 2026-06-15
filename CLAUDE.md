# Agentic Platform — Claude Context

Design spec: `../agentic-platform-design.md` (original architecture, milestones)
Status detail: `SETUP-STATUS.md` (current, accurate)

> Roles: **qwen3-coder = brain + code executor** · **bash driver = orchestration** ·
> **Claude + Logan = plan & monitor**.

## Hardware

| Machine | Tailscale name | Role |
|---------|---------------|------|
| MacBook Pro M3 | — | Architect console (Logan + Claude: plan/monitor) |
| Mac Mini M1 | `mac-mini-ca-namto` | Orchestrator — runs the pipeline 24/7 |
| RTX 5090 server | `milai` / `100.107.129.18` | Ollama inference + CI runner + dead-man |

Network: Tailscale mesh. `ssh milai` from M1. No public ports.

## Inference Stack

**Ollama** at `http://milai:11434`.

| Model | num_ctx / temp | Role |
|-------|----------------|------|
| `qwen3-coder-wms:latest` | 32768 / 0.2 | **Brain + executor** (Goose nightly + aider) |
| `qwen3-coder:30b-a3b-q4_K_M` | default / 0.7 | base, not used by live pipeline |

Goose config: `~/.config/goose/config.yaml` — `ollama` / `qwen3-coder-wms:latest`.
aider config: `~/.aider.conf.yml` + `~/.aider.model.settings.yml` (mirrored in `infra/m1/`).

## How dispatch works (IMPORTANT — not LLM-orchestrated)

The live loop is **deterministic bash** (`scripts/run-pipeline.sh`); the LLM only writes code:

```
claim agent:ready → render task → aider (qwen3-coder) implements →
run REAL test (scripts/ci-test.sh, same as CI) → 1 corrective retry →
pass → push + PR ("Closes #N") + agent:review
fail → agent:blocked + log comment + Telegram
```

Earlier the Goose **recipe** drove this with the LLM and derailed (skipped steps, stuck
`agent:wip`). That recipe + `execute-task.sh` + `verify.sh` are **DEPRECATED** — do not
re-wire them.

## Milestone Status

| Milestone | Status | Notes |
|-----------|--------|-------|
| **M0** Network + inventory | ✅ | Tailscale · SSH · `gh auth` |
| **M1** Inference backend | ✅ | Ollama + qwen3-coder, ~140 tok/s |
| **M2** Orchestrator core | ✅ | agent:ready → PR autonomously |
| **M3** Verification & CI | ✅ | Real test gate; blocked path proven (#19); runner + branch protection + CI |
| **M4** Scheduling & ops | ✅ | launchd autostart · nightly digest · 3-layer Telegram alerting · remote control |
| **M5** Pilot | ⏳ | Real ≥5-issue project through the pipeline |

## Live jobs (launchd / cron)

`goose-scheduler` (driver, 15m) · `goose-nightly` (digest, 06:30) ·
`goose-watchdog` (health→Telegram, 15m) · `telegram-control` (commands, KeepAlive) ·
RTX `deadman.sh` (cron, 15m).

## Observability & control (Telegram)

- Alerting: heartbeat-on-success + watchdog + RTX dead-man. "Silence = alarm."
  Config: `~/.config/agentic/alert.env` (M1) and `~/.agentic/alert.env` (RTX).
- Remote control: `/status /dispatch /retry N /pause /resume /help`; free-text → new
  `agent:ready` issue. (`scripts/telegram-control.sh`)

## Key Files

```
scripts/run-pipeline.sh     ← LIVE deterministic dispatch driver
scripts/dispatch.sh         ← claim issue + worktree (used by driver)
scripts/render-task.sh      ← issue → task.md (used by driver)
scripts/run-job.sh          ← wrapper: heartbeat + failure alert
scripts/healthcheck.sh      ← watchdog
scripts/notify-telegram.sh  ← alert channel
scripts/telegram-control.sh ← two-way control listener
scripts/ci-test.sh          ← test runner (driver gate + CI)
infra/m1/*.plist            ← LaunchAgents (scheduler/nightly/watchdog/telegram)
infra/m1/aider.*.yml        ← aider executor config
infra/rtx/deadman.sh        ← cross-machine dead-man
scripts/{execute-task,verify}.sh, recipes/dispatch-issues.yaml  ← DEPRECATED
```

## Quick Commands

```bash
ssh milai "ollama list"
bash scripts/run-pipeline.sh "namlogan/agentic-platform" "$HOME/agent-work"  # manual pass
launchctl list | grep -E "goose|telegram"
bash scripts/telegram-control.sh --handle "/status"
gh api repos/namlogan/agentic-platform/actions/runners | jq '.runners[]|{name,status}'
```

## Repo

`namlogan/agentic-platform` on GitHub (personal account). `main` is protected
(requires `test` CI + 1 review; admin-merge used for solo operation).
