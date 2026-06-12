# Agentic Platform — Setup Status

**Last Updated:** 2026-06-12 18:45

---

## Infrastructure Overview

| Component | Device | Role | Status |
|-----------|--------|------|--------|
| **M3** | MacBook Pro M3 | Architect | ✅ Active |
| **M1** | Mac Mini M1 (`mac-mini-ca-namto`) | Orchestrator | ✅ Active |
| **RTX** | RTX 5090 Server (`milai`, `100.107.129.18`) | Inference Backend | ✅ Active |

---

## Network Configuration

| Check | Status |
|-------|--------|
| Tailscale mesh (M1 ↔ RTX) | ✅ |
| SSH key-based M1 → RTX (`ssh milai`) | ✅ |
| GitHub CLI (`gh auth`) on M1 | ✅ |
| RTX Ollama endpoint accessible from M1 | ✅ `http://100.107.129.18:11434` |

---

## Milestone Progress

### ✅ M0 — Network & Inventory (COMPLETE)
**Acceptance:** `tailscale ping` both directions ✅ · `gh issue list` from M1 ✅

---

### ✅ M1 — Inference Backend (COMPLETE)
**Backend:** Ollama (instead of vLLM — simpler setup, functionally equivalent)

| Check | Status |
|-------|--------|
| Ollama installed + systemd service | ✅ |
| GPU detected: RTX 5090 (31.4 GiB VRAM) | ✅ |
| Endpoint `http://milai:11434` accessible from M1 | ✅ |
| Model `qwen2.5-coder:14b` (9 GB) loaded | ✅ |
| Model `llama3.2:3b` (2 GB) loaded | ✅ Native tool calling ✅ |
| Model `qwen2.5:7b` (4.7 GB) | 🔄 Downloading (~47%, ETA ~30 min) |
| Inference speed | ✅ **140 tok/s** (target: ≥20) |

**Note:** `qwen2.5-coder:14b` outputs tool calls as text (not structured), so it cannot be used as the Goose orchestrator brain. `llama3.2:3b` supports native tool calling but is too small for quality reasoning. `qwen2.5:7b` is the target model.

---

### 🔄 M2 — Orchestrator Core (IN PROGRESS)

| Check | Status |
|-------|--------|
| Goose CLI v1.37.0 installed | ✅ `~/.local/bin/goose` |
| Goose Desktop App installed | ✅ `/Applications/Goose.app` |
| Goose config (`~/.config/goose/config.yaml`) | ✅ Provider: `ollama`, Model: `llama3.2:3b` (temp) |
| Goose connects to RTX Ollama | ✅ (`goose doctor` passes) |
| Goose tools execute (shell, edit) | ✅ Confirmed with `llama3.2:3b` |
| Schedules registered | ✅ `dispatch-issues` (*/15min), `nightly-report` (06:30) |
| GitHub labels created | ✅ All 9 labels in `namlogan/agentic-platform` |
| Toy test issue created | ✅ Issue #1 labeled `agent:ready` |
| **End-to-end dispatch test** | ⏳ Blocked on `qwen2.5:7b` download |

**Acceptance pending:** Hand-labeled `agent:ready` issue → PR opens autonomously.

---

### 🔄 M3 — Verification & CI (IN PROGRESS)

| Check | Status |
|-------|--------|
| `verify.sh` updated for Ollama endpoint | ✅ |
| Self-hosted runner download on RTX | 🔄 In progress |
| Branch protection on `main` | ⏳ After runner registered |
| CI workflow `.github/workflows/ci.yml` | ✅ |

---

### ⏳ M4 — Scheduling & Ops (PENDING)
Waiting for M3.

---

### ⏳ M5 — Pilot (PENDING)
Waiting for M4.

---

## Active Background Tasks

| Task | Status | ETA |
|------|--------|-----|
| `qwen2.5:7b` download on RTX | 🔄 47% (2.2/4.7 GB) | ~30 min |
| GitHub Actions runner download on RTX | 🔄 In progress | ~10 min |

---

## Model Decision

| Model | Size | Tool Calling | Quality | Role |
|-------|------|-------------|---------|------|
| `qwen2.5-coder:14b` | 9 GB | ❌ Text-only | High for code | Code review LLM (verify.sh) |
| `llama3.2:3b` | 2 GB | ✅ Structured | Low (too small) | Testing only |
| `qwen2.5:7b` | 4.7 GB | ✅ Structured | Good | **Goose orchestrator brain** |

**Final config:** Goose brain = `qwen2.5:7b` · LLM review = `qwen2.5-coder:14b`

---

## Quick Commands

```bash
# Check RTX inference
ssh milai "ollama list"
curl http://100.107.129.18:11434/api/tags

# Check Goose
~/.local/bin/goose doctor
~/.local/bin/goose schedule list

# Check runner
gh api repos/namlogan/agentic-platform/actions/runners | jq '.runners[]|{name,status}'

# Monitor model download
ssh milai "tail -f /tmp/qwen25-7b-pull.log 2>/dev/null | strings | grep '%'"

# Run dispatch recipe manually
cd ~/Desktop/agentic-platform
~/.local/bin/goose run \
  --no-session --max-turns 20 \
  --recipe recipes/dispatch-issues.yaml \
  --params REPOS=namlogan/agentic-platform \
  --params BASE_DIR=$HOME/agent-work
```

---

## Next Steps

1. ⏳ Wait for `qwen2.5:7b` download (~30 min)
2. Update Goose config: `GOOSE_MODEL: qwen2.5:7b`
3. Complete GitHub Actions runner registration
4. Enable branch protection on `main`
5. Run end-to-end dispatch test (Issue #1)
6. Mark M2 + M3 complete if acceptance passes
