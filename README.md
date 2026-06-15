# agentic-platform

Autonomous dev pipeline: Claude plans → GitHub queues → Goose orchestrates → auggie implements → CI verifies → Logan approves.

## Quick-start

See [docs/DESIGN.md](docs/DESIGN.md) for the full architecture and rationale.

### Machine roles

| Machine | Tailscale name | Role |
|---|---|---|
| MacBook Pro M3 | `macs-macbook-pro` | Architect console (Logan + Claude Pro) |
| Mac Mini M1 | `mac-mini-ca-namto` | Goose orchestrator (24/7) |
| RTX 5090 server | `milai` | vLLM inference + CI runner + sandbox |

### Runbook

- **Queue stuck?** `gh issue list -l agent:wip` — if older than 1 h, check `~/agent-work/.../result.log`, relabel `agent:ready` to retry.
- **vLLM down?** Goose falls back to Anthropic API only if `FALLBACK_API=1` is set; default is to pause dispatch and open an `agent:blocked` infra issue.
- **Kill switch:** remove `agent:ready` labels, or `launchctl unload ~/Library/LaunchAgents/com.logan.goose-scheduler.plist`.
- **Upgrades:** pin goose + vLLM versions in `infra/`; bump monthly via a dedicated issue.

### Alerting (so failures are never silent)

Principle: **healthy = an active heartbeat**; silence is treated as failure (this is
what was missing when the pipeline 404'd silently for ~1.5 days). Three layers:

1. **Heartbeat on success** — every scheduled job runs via `scripts/run-job.sh`, which
   writes `~/.config/agentic/state/heartbeat-<job>` on exit 0 and alerts after
   `FAIL_THRESHOLD` (default 2) consecutive failures, with the log tail attached.
2. **Watchdog** (`scripts/healthcheck.sh`, `com.logan.goose-watchdog` every 15 min) —
   independent of Goose/Ollama; checks Ollama reachable + model present, heartbeat
   freshness, stuck `agent:wip` (>90 min), and `agent:blocked` issues.
3. **Dead-man switch on RTX** (`infra/rtx/deadman.sh`, cron every 15 min) — M1 pushes its
   heartbeat to the always-on RTX; if it goes stale (>60 min) the RTX alerts. Catches the
   one case the on-box watchdog can't report: the whole Mac Mini being down.

All alerts go to **Telegram**. To enable: copy `infra/m1/alert.env.example` →
`~/.config/agentic/alert.env` on M1 **and** `~/.agentic/alert.env` on RTX, filling in
`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` (see the example file for the 30-second
@BotFather steps). Until then, alerts are logged to
`~/.config/agentic/state/alerts.log` and the system keeps running.
Test anytime: `bash scripts/notify-telegram.sh test "hello from agentic-platform"`.

### Labels (state machine)

| Label | Set by | Meaning |
|---|---|---|
| `status:spec` | Logan | Claude is/should be drafting spec |
| `agent:ready` | Logan | Spec complete, queued for dispatch |
| `agent:wip` | Goose | Claimed by orchestrator |
| `agent:review` | Goose | PR opened, awaiting human review |
| `agent:blocked` | Goose | Failed twice or needs decision |
| `priority:p0/p1/p2` | Logan/Claude | Dispatch order |
| `design-question` | Agent | Ambiguity needing Logan input |

### Milestones

- **M0** Network & inventory — Tailscale mesh, SSH M1→RTX, `gh auth` on M1
- **M1** Inference backend — vLLM + model on RTX, systemd, smoke test
- **M2** Orchestrator core — Goose + scripts, worktree lifecycle, end-to-end toy issue
- **M3** Verification & CI — `verify.sh`, self-hosted runner, branch protection
- **M4** Scheduling & ops — Goose cron, launchd autostart, nightly digest
- **M5** Pilot — real project, ≥5 issues, ≥80% autonomous completion rate
