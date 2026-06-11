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
