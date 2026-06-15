# Agentic Platform — Setup Status

**Last Updated:** 2026-06-15 — M0–M4 ✅ · M5 pending

---

## Infrastructure

| Component | Device | Role | Status |
|-----------|--------|------|--------|
| **M3** | MacBook Pro M3 | Architect console (Logan + Claude: plan & monitor) | ✅ |
| **M1** | Mac Mini M1 (`mac-mini-ca-namto`) | Orchestrator — runs the pipeline 24/7 | ✅ |
| **RTX** | RTX 5090 (`milai`, `100.107.129.18`) | Ollama inference + CI runner + dead-man | ✅ |

Network: Tailscale mesh · `ssh milai` key-based · `gh auth` on M1 · Ollama at `http://milai:11434`.

---

## Architecture (as built)

The dispatch loop is a **deterministic bash driver** — not LLM-orchestrated. The LLM
(qwen3-coder via aider) only writes code; every state transition is bash.

```
com.logan.goose-scheduler (every 15m)
  └─ run-job.sh dispatch -- run-pipeline.sh <repos>
       claim agent:ready → render task → aider implements →
       run REAL test (ci-test.sh, same as CI) → 1 corrective retry →
       pass: push + PR (Closes #N) + agent:review
       fail: agent:blocked + log comment + Telegram
```

**Models on RTX** (Ollama):
| Model | num_ctx | temp | Role |
|-------|---------|------|------|
| `qwen3-coder-wms:latest` | 32768 | 0.2 | **Brain + code executor** (Goose + aider) |
| `qwen3-coder:30b-a3b-q4_K_M` | default | 0.7 | base (not used by the live pipeline) |

**Executor:** aider (`ollama_chat/qwen3-coder-wms`, edit_format `whole`, num_ctx 32768).
Config in `infra/m1/aider.conf.yml` + `aider.model.settings.yml` (live copies in `$HOME`).

---

## Live LaunchAgents / cron

| Job | Role | Cadence |
|-----|------|---------|
| `com.logan.goose-scheduler` | deterministic dispatch driver | every 15m |
| `com.logan.goose-nightly` | digest issue (Goose, model `qwen3-coder-wms`) | 06:30 |
| `com.logan.goose-watchdog` | health monitor → Telegram | every 15m |
| `com.logan.telegram-control` | two-way Telegram command listener | KeepAlive |
| `deadman.sh` (on RTX, cron) | cross-machine dead-man switch | every 15m |

---

## Milestones

| Milestone | Status | Evidence |
|-----------|--------|----------|
| **M0** Network & inventory | ✅ | Tailscale, SSH, `gh auth` |
| **M1** Inference backend | ✅ | Ollama on RTX, qwen3-coder, ~140 tok/s |
| **M2** Orchestrator core | ✅ | agent:ready → PR autonomously (many) |
| **M3** Verification & CI | ✅ | Real test gate in driver; **blocked path proven** (#19 → agent:blocked + log + Telegram); self-hosted runner + branch protection + CI |
| **M4** Scheduling & ops | ✅ | launchd autostart, nightly digest (#5/#6), 3-layer alerting, Telegram remote control |
| **M5** Pilot | ⏳ | Not started — real ≥5-issue project through the pipeline |

---

## Observability & control

- **Alerting (Telegram):** healthy = active heartbeat; silence = alarm. Layers:
  heartbeat-on-success (`run-job.sh`), watchdog (`healthcheck.sh`), RTX dead-man
  (`deadman.sh`). Config: `~/.config/agentic/alert.env` (M1) + `~/.agentic/alert.env` (RTX).
- **Remote control (Telegram):** `/status`, `/dispatch`, `/retry N`, `/pause`, `/resume`,
  `/help`; free-text → new `agent:ready` issue. Listener: `telegram-control.sh`.

---

## Deprecated (superseded, kept for reference)

- `scripts/execute-task.sh` — old executor contract (bypassed in practice)
- `scripts/verify.sh` — Docker+LLM verifier (replaced by the driver's test gate)
- `recipes/dispatch-issues.yaml` — LLM-orchestrated dispatch (derailed; replaced by `run-pipeline.sh`)

---

## Quick commands

```bash
# Inference
ssh milai "ollama list"; curl http://milai:11434/api/tags

# Run a dispatch pass manually
cd ~/agentic-platform
bash scripts/run-pipeline.sh "namlogan/agentic-platform" "$HOME/agent-work"

# Jobs
launchctl list | grep -E "goose|telegram"
tail -f ~/.config/agentic/state/last-dispatch.log

# Alerting / control test
bash scripts/notify-telegram.sh test "ping"
bash scripts/telegram-control.sh --handle "/status"
```

---

## Next: M5 — Pilot

Plan a real ≥5-issue milestone (e.g. in `namlogan/warehouse-agentic`) with Claude,
label `agent:ready`, and measure: % reaching `agent:review` unattended, blocked rate,
throughput. Target: ≥80% autonomous, zero pushes outside `agent/*`.
