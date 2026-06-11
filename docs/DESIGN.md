# Agentic-as-a-Service Platform — Implementation Design

> **Purpose:** This document is an executable spec. It is written to be handed to an implementation agent (Claude Code, Goose, or auggie). Work through the milestones in §8 in order. Every milestone has acceptance criteria — do not proceed until they pass.
>
> **Owner:** Logan · **Date:** 2026-06-11 · **Status:** Approved for implementation

---

## 1. Goals & Non-Goals

**Goals**

- A 24/7 autonomous dev pipeline: Claude designs work → GitHub coordinates it → an orchestrator agent on the Mac Mini M1 dispatches it → auggie (Augment CLI) implements it → results are verified and returned as PRs.
- Use the RTX 5090 server as a local LLM inference backend so routine agent work costs $0 in API tokens.
- Everything reproducible from this repo: configs, recipes, scripts, CI.

**Non-Goals (v1)**

- No multi-tenant SaaS frontend yet. v1 is the internal engine; productizing "agentic as a service" for external customers is a later phase built on top of this.
- No autonomous merges to `main`. Humans (Logan) approve all PRs in v1.

---

## 2. Inventory

| Asset | Spec | Role in system |
|---|---|---|
| Mac Mini M1 (home, 24/7) | Apple Silicon, always-on | **Orchestrator** — runs Goose + dispatcher scripts |
| MacBook Pro M3 (daily driver) | mobile, 07:00–16:00 | **Architect console** — Logan + Claude (Claude Pro) plan & review |
| RTX 5090 server | 32 GB VRAM, 125 GB RAM | **Inference + execution backend** — vLLM, sandbox, CI runner |
| Claude Pro (personal) | claude.ai / Claude Code | Planning, spec-writing, code review |
| Augment Enterprise (auggie, non-interactive) | company-issued | **Coder/executor** via `auggie --print` |
| GitHub (personal account) | free/pro | **Coordination bus** — issues, milestones, PRs, Actions |

> ⚠️ **Compliance note:** the Augment account is company-issued. Before wiring it into personal-project automation, confirm the company's acceptable-use policy permits this. If not, substitute the executor with Claude Code headless or a local-model agent (the architecture is executor-agnostic by design — see §4.3 "Executor contract").

---

## 3. Architecture Overview

```
┌──────────────────────┐        ┌─────────────────────────────┐
│  MacBook Pro M3      │        │  GitHub (coordination bus)  │
│  "ARCHITECT"         │ issues │  - Issues + labels          │
│  Logan + Claude Pro  ├───────►│  - Milestones / Projects    │
│  (plan, spec, review)│  PRs   │  - PRs + branch protection  │
└──────────────────────┘ review │  - Actions (CI)             │
                        ◄───────┤                             │
                                └──────┬──────────────▲───────┘
                                  poll │ agent:ready  │ PR + status
                                       ▼              │
                        ┌──────────────────────────────────┐
                        │  Mac Mini M1 (24/7)              │
                        │  "ORCHESTRATOR" — Goose          │
                        │  - scheduled recipe polls GitHub │
                        │  - prepares worktree per issue   │
                        │  - invokes executor (auggie)     │
                        │  - verifies: tests, lint, review │
                        │  - opens PR, updates issue       │
                        └───────┬──────────────────┬───────┘
                        LLM API │ (OpenAI-compat)  │ SSH (heavy jobs)
                                ▼                  ▼
                        ┌──────────────────────────────────┐
                        │  RTX 5090 server "BACKEND"       │
                        │  - vLLM serving local model      │
                        │  - self-hosted GH Actions runner │
                        │  - Docker sandbox for exec/tests │
                        │  - (optional) auggie worker host │
                        └──────────────────────────────────┘
```

**Networking:** all three machines join one **Tailscale** tailnet. No ports exposed to the internet. The vLLM endpoint, SSH, and runner traffic stay inside the mesh.

**Why this shape**

- *Goose on M1*: open source (Block), has native **recipes** (YAML-defined repeatable agent jobs), a built-in **cron scheduler**, headless CLI, and MCP support — exactly the dispatcher profile needed, and light enough for an M1.
- *GitHub as the bus*: issues/labels are the queue; PRs are the deliverable; Actions is the verification gate. No custom queue infra to maintain.
- *RTX as inference*: Goose's own reasoning (triage, verification summaries, retries) points at the local vLLM endpoint → near-zero marginal cost. Claude Pro is reserved for high-value planning/review; auggie for implementation.

---

## 4. Component Design

### 4.1 RTX 5090 server — inference backend

1. **OS prep:** Ubuntu 24.04 LTS, NVIDIA driver ≥ 570, CUDA 12.8+, Docker + nvidia-container-toolkit, Tailscale.
2. **vLLM** (Docker) serving an OpenAI-compatible API on `:8000`.
   - **Primary model:** `Qwen/Qwen3-32B-AWQ` (4-bit) — strong agentic/coding model, fits 32 GB VRAM with ~32k context. Verify the current best ~30B coding model at implementation time and substitute if a better Apache/MIT option exists (e.g. Devstral-Small successor).
   - **Fallback small model:** `Qwen3-8B` via a second vLLM instance or Ollama, for cheap classification/summarization.
3. **systemd unit** so vLLM survives reboots (Appendix A.1).
4. **Self-hosted GitHub Actions runner** registered to the project org/repos, labeled `rtx5090`. Runs in Docker; executes test suites, builds, and GPU jobs.
5. **Sandbox:** all executor-generated code runs tests inside Docker containers on this machine, never on the M1 host directly.

Additional roles this box should take on (owner-approved):

- **Embeddings + RAG service** (e.g. `text-embedding` model via vLLM or Infinity) for cross-repo memory/context lookup by agents.
- **Artifact cache:** Docker registry mirror + pip/npm cache to speed up CI.
- **Nightly batch jobs:** large-context tasks (repo-wide audits, doc generation) scheduled when interactive load is zero.

### 4.2 Mac Mini M1 — Goose orchestrator

1. Install: `brew install block/tap/goose` (+ `gh` CLI, `git`, `jq`, `tailscale`).
2. **Provider config** (`~/.config/goose/config.yaml`): OpenAI-compatible provider pointing at `http://rtx5090.tailnet:8000/v1`, model = the vLLM-served model. Goose's own reasoning therefore runs free on local GPU.
3. **Recipes** (committed in this repo under `recipes/`):
   - `dispatch-issues.yaml` — the main loop (Appendix A.2). Polls GitHub every 15 min for `agent:ready` issues, claims one, runs the pipeline in §5.
   - `verify-pr.yaml` — re-runs verification on PRs labeled `agent:review`.
   - `nightly-report.yaml` — 06:30 daily digest issue: what was completed, what's blocked, queue depth. Ready for Logan to read at 07:00.
4. **Scheduling:** use Goose's built-in scheduler (cron syntax) for the three recipes; wrap the goose daemon in a **launchd** plist so it auto-starts on boot (Appendix A.3).
5. **Concurrency:** max 1 issue in flight per repo (git worktree per issue under `~/agent-work/<repo>/<issue-number>`); global max 2.

### 4.3 Executor contract (auggie)

The orchestrator never assumes *which* coder it calls. It calls an **executor interface**: a script `scripts/execute-task.sh <worktree> <taskfile>` that must return JSON `{"status": "done|failed|blocked", "summary": "...", "files_changed": [...]}` on stdout.

**v1 implementation = auggie:**

```bash
cd "$WORKTREE"
auggie --print --quiet \
  "$(cat "$TASKFILE")" \
  > result.log 2>&1
```

- `--print` = single-shot non-interactive run; `--quiet` = final output only. Designed for CI/automation.
- auggie auto-indexes the project directory it runs in → run it inside the issue worktree so its context engine sees the right code.
- **Task file template** (generated by the dispatcher from the issue body):

```markdown
## Task
<issue title>

## Spec
<issue body — written by Claude, see §5 step 1>

## Constraints
- Branch: agent/<issue-number>-<slug> (already checked out)
- Make atomic commits with conventional-commit messages
- All existing tests must pass: `<test command from repo's AGENT.md>`
- Add tests for new behavior
- Do NOT touch files outside the scope listed in the spec
- When finished, print a one-paragraph summary of changes

## Definition of Done
<acceptance criteria from issue>
```

- **Timeout:** 30 min per attempt, max 2 attempts. On second failure → label `agent:blocked`, comment the log tail on the issue.
- Swappable executors: `execute-task.sh --executor=claude-code` (uses `claude -p`) and `--executor=local` (Goose subagent on vLLM) implemented as fallbacks.

### 4.4 GitHub workflow design

**Labels (the state machine):**

| Label | Meaning | Set by |
|---|---|---|
| `status:spec` | Claude is/should be drafting spec | Logan |
| `agent:ready` | Spec complete, queued for dispatch | Logan (manual gate) |
| `agent:wip` | Claimed by orchestrator | Goose |
| `agent:review` | PR opened, awaiting human review | Goose |
| `agent:blocked` | Failed twice or needs decision | Goose |
| `priority:p0/p1/p2` | Dispatch order | Logan/Claude |

**Rules**

- Issues are the only work-intake. One issue = one branch = one PR.
- Branch naming: `agent/<issue>-<slug>`. PRs use `Closes #<issue>`.
- `main` is protected: required CI checks (self-hosted `rtx5090` runner), 1 human approval.
- Milestones group issues per project phase; Claude proposes milestone plans (§5 step 1), Logan approves by applying `agent:ready`.
- Optional: install `anthropics/claude-code-action` so `@claude` in PR comments does automated code review with the Claude Pro account.

---

## 5. End-to-End Workflow

1. **Plan (MacBook M3, 07:00–16:00 or evenings).** Logan describes a feature/project to Claude. Claude analyzes the codebase, writes the breakdown: milestone definition, issues with full specs (context, approach, file scope, acceptance criteria, test plan), dependency order. Claude creates them via `gh` CLI / GitHub MCP. Each issue gets `status:spec`.
2. **Gate.** Logan reviews specs, fixes priorities, flips label to `agent:ready`. *(This 30-second human gate is what keeps the autonomous loop safe.)*
3. **Dispatch (Mac Mini, any time).** Goose's `dispatch-issues` recipe finds the highest-priority `agent:ready` issue with no unmet dependencies → labels `agent:wip`, comments "claimed", clones/updates repo, creates worktree + branch.
4. **Execute.** Dispatcher renders the task file and calls the executor (auggie, §4.3).
5. **Verify (local).** Goose runs the repo's test + lint commands in a Docker sandbox (heavy suites via SSH on RTX). Then a **review pass on the local vLLM model**: diff + spec → "does the diff satisfy the acceptance criteria? list gaps." Gaps → one corrective auggie run.
6. **Deliver.** Push branch, open PR with summary + test results, label `agent:review`, comment on the issue.
7. **CI gate.** GitHub Actions on the `rtx5090` runner re-runs the full suite. Red CI → Goose gets one auto-fix attempt, else `agent:blocked`.
8. **Review & merge (MacBook M3).** Logan reviews (optionally `@claude` review first), merges. Issue auto-closes. Next morning's `nightly-report` summarizes everything.

---

## 6. Security

- **Tailscale-only** connectivity; vLLM and SSH bound to tailnet interface. No public ports.
- **Secrets:** fine-grained GitHub PAT (repo-scoped, issues+contents+PR) in macOS Keychain on the M1, read by scripts at runtime; Augment auth is **non-interactive**: store the session token in macOS Keychain and export it as `AUGMENT_SESSION_AUTH` (verify exact env var against current Augment enterprise docs) in the dispatcher environment — never call `auggie login` interactively; runner registration token on RTX only. Nothing in the repo.
- **Blast radius:** executor only ever pushes to `agent/*` branches; branch protection on `main`; PAT cannot administer the repo.
- Executor runs as an unprivileged user; tests in Docker with no host mounts beyond the worktree.

---

## 7. Repository Layout (this platform repo: `agentic-platform`)

```
agentic-platform/
├── README.md                  # quickstart, links here
├── docs/DESIGN.md             # this file
├── recipes/                   # goose recipes (dispatch, verify, nightly)
├── scripts/
│   ├── dispatch.sh            # poll + claim logic (gh + jq)
│   ├── execute-task.sh        # executor interface (auggie/claude/local)
│   ├── verify.sh              # tests + lint + LLM review
│   └── render-task.sh         # issue → task file
├── infra/
│   ├── rtx/ (vllm.service, runner-setup.sh, docker-compose.yml)
│   └── m1/  (launchd plist, goose config template, bootstrap.sh)
├── templates/ (issue templates, PR template, AGENT.md template)
└── .github/workflows/ci.yml
```

Each *managed project repo* additionally carries an `AGENT.md` (test command, lint command, file-scope conventions) that the dispatcher reads.

---

## 8. Implementation Milestones

**M0 — Network & inventory (½ day)**
Tailscale on all 3 machines; SSH M1→RTX key-based; `gh auth` on M1.
*Accept:* `tailscale ping` both directions; `gh issue list` works from M1.

**M1 — Inference backend (1 day)**
vLLM + model on RTX, systemd, smoke test.
*Accept:* `curl http://rtx:8000/v1/chat/completions` returns valid completion from M1; survives reboot; ≥20 tok/s.

**M2 — Orchestrator core (2 days)**
Goose installed + provider on vLLM; `dispatch.sh`, `render-task.sh`, `execute-task.sh` (auggie path), worktree lifecycle; labels created in a **test repo**.
*Accept:* hand-labeled `agent:ready` toy issue ("add a hello endpoint + test") → PR opens autonomously with passing local tests, issue transitions wip→review.

**M3 — Verification & CI (1–2 days)**
`verify.sh` (sandboxed tests + vLLM review pass), self-hosted runner on RTX, branch protection, `ci.yml`.
*Accept:* a deliberately broken executor output gets caught: red CI, auto-fix attempt, `agent:blocked` on second failure with log comment.

**M4 — Scheduling & ops (1 day)**
Goose scheduler entries, launchd autostart, `nightly-report` recipe, runbook in README.
*Accept:* M1 reboot → loop resumes unattended; nightly digest issue appears at 06:30.

**M5 — Pilot (1 week soak)**
Run a real personal project through the pipeline: Claude plans a milestone of ≥5 issues; measure throughput, failure rate, token spend.
*Accept:* ≥80% of issues reach `agent:review` without human intervention; zero pushes outside `agent/*`.

---

## 9. Runbook (ops quick reference)

- Queue stuck? `gh issue list -l agent:wip` — if older than 1 h, check `~/agent-work/.../result.log`, relabel `agent:ready` to retry.
- vLLM down? Goose falls back to Anthropic API only if `FALLBACK_API=1` is set; default is to pause dispatch and open a `agent:blocked` infra issue.
- Kill switch: remove `agent:ready` labels, or `launchctl unload` the goose plist.
- Upgrades: pin goose + vLLM versions in `infra/`; bump monthly via a dedicated issue (the system can dogfood its own upgrades).

---

## Appendix A — Reference Configs

### A.1 `infra/rtx/vllm.service`

```ini
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target docker.service
[Service]
ExecStart=/usr/bin/docker run --rm --gpus all -p 8000:8000 \
  -v /opt/models:/models vllm/vllm-openai:latest \
  --model Qwen/Qwen3-32B-AWQ --max-model-len 32768 \
  --gpu-memory-utilization 0.92
Restart=always
[Install]
WantedBy=multi-user.target
```

### A.2 `recipes/dispatch-issues.yaml` (sketch)

```yaml
version: 1.0.0
title: dispatch-issues
description: Claim one agent:ready issue and run it through the pipeline
instructions: |
  1. Run scripts/dispatch.sh to claim the top-priority agent:ready issue.
     If none, exit quietly.
  2. Run scripts/render-task.sh <issue> to produce the task file.
  3. Run scripts/execute-task.sh <worktree> <taskfile> (executor: auggie).
  4. Run scripts/verify.sh <worktree>. If gaps reported, one corrective
     executor run, then verify again.
  5. On success: push branch, gh pr create, relabel agent:review.
     On failure: relabel agent:blocked, comment log tail on the issue.
extensions:
  - type: builtin
    name: developer
settings:
  goose_provider: openai_compatible   # → RTX vLLM
schedule: "*/15 * * * *"
```

### A.3 `infra/m1/com.logan.goose-scheduler.plist` (launchd)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.logan.goose-scheduler</string>
  <key>ProgramArguments</key>
  <array><string>/opt/homebrew/bin/goose</string>
         <string>scheduler</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/logan/Library/Logs/goose.log</string>
  <key>StandardErrorPath</key><string>/Users/logan/Library/Logs/goose.err</string>
</dict></plist>
```

### A.4 Executor call (auggie, non-interactive)

```bash
auggie --print --quiet "$(cat task.md)"   # single-shot, automation-safe
```

### A.5 `.github/workflows/ci.yml` (sketch)

```yaml
name: ci
on: [pull_request]
jobs:
  test:
    runs-on: [self-hosted, rtx5090]
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/ci-test.sh   # reads AGENT.md for repo test cmd
```

---

## Appendix B — Instruction to the Implementation Agent

You are implementing this design. Rules:

1. Execute milestones **M0 → M5 in order**; stop at each acceptance gate and report results before continuing.
2. Create the `agentic-platform` repo with the layout in §7; commit every config/script you produce.
3. Ask Logan before: installing anything on the RTX server beyond §4.1, storing any credential, or changing label/branch conventions.
4. At implementation time, re-verify current versions/models (goose, vLLM, best ≤32B coding model, auggie flags) — this doc was written 2026-06-11 and the ecosystem moves fast.
5. Anything ambiguous → open a GitHub issue labeled `design-question` rather than guessing.
