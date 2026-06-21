#!/usr/bin/env python3
"""AgentScope coding executor — the "loop engineer" brain of the factory.

Honors the executor contract of scripts/execute-task.sh:
    Usage:  agentscope_executor.py <worktree> [taskfile]
    stdout: a single JSON line {"status","summary","files_changed","model","iters"}
    stderr: progress / agent trajectory
    exit 0 always (status lives in the JSON)

Brain tiering (per project decision):
    Tier 1  Nex-V2-Pro  (nex-agi/nex-n2-pro:free via OpenRouter, OpenAI-compatible)
    Tier 2  Claude Opus 4.8 (Anthropic API if ANTHROPIC_API_KEY else `claude -p` CLI)

Escalation is driven by the deterministic TEST GATE: a tier "passes" only when the
test command exits 0 AND the worktree has uncommitted/added changes. If Nex cannot
make the tests pass within max_iters, we re-run a fresh agent on Claude.

Env (source ~/.config/agentic/models.env first):
    OPENROUTER_API_KEY   required for the Nex tier
    NEX_BASE_URL         default https://openrouter.ai/api/v1
    NEX_MODEL            default nex-agi/nex-n2-pro:free
    ANTHROPIC_API_KEY    optional; enables in-loop Claude tier
    CLAUDE_MODEL         default claude-opus-4-8
    TEST_CMD             optional override; else ci-test.sh / AGENT.md / pytest
    MAX_ITERS            default 18
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
from contextlib import redirect_stdout
from pathlib import Path


def log(*a: object) -> None:
    print("[agentscope-executor]", *a, file=sys.stderr, flush=True)


def run(cmd: list[str] | str, cwd: str, timeout: int = 900) -> tuple[int, str]:
    shell = isinstance(cmd, str)
    p = subprocess.run(
        cmd, cwd=cwd, shell=shell, capture_output=True, text=True, timeout=timeout
    )
    return p.returncode, (p.stdout + p.stderr)


def resolve_test_cmd(worktree: str) -> str:
    if os.environ.get("TEST_CMD"):
        return os.environ["TEST_CMD"]
    if Path(worktree, "scripts", "ci-test.sh").exists():
        return "bash scripts/ci-test.sh"
    agent_md = Path(worktree, "AGENT.md")
    if agent_md.exists():
        for line in agent_md.read_text(errors="ignore").splitlines():
            s = line.strip()
            if s.lower().startswith("test:"):
                return s.split(":", 1)[1].strip().strip("`")
    return "python3 -m pytest -q"


def changed_files(worktree: str) -> list[str]:
    code, out = run(["git", "status", "--porcelain"], worktree)
    files = []
    for line in out.splitlines():
        if line.strip():
            files.append(line[3:].strip())
    return files


def test_passes(worktree: str, test_cmd: str) -> tuple[bool, str]:
    log(f"TEST GATE: {test_cmd}")
    code, out = run(test_cmd, worktree)
    tail = "\n".join(out.splitlines()[-25:])
    log(f"TEST GATE exit={code}")
    return code == 0, tail


SYS_PROMPT_TMPL = """You are an autonomous senior software engineer working INSIDE a git worktree.
Your job: fully implement the task described by the user by creating and editing real files,
then make the project's tests pass.

PROJECT ROOT (absolute): {root}

Path rules (CRITICAL):
- Every file you read, write, or edit MUST live under {root}.
- Use paths RELATIVE to the project root (e.g. "src/app.py"), or absolute paths that
  start with {root}. NEVER write to a path that starts with "/" outside {root}.
- The Bash tool already runs with its working directory set to the project root.

Workflow rules:
- Use the Bash, Read, Write, Edit, Grep tools to inspect and change the code.
- Run the test command yourself, read failures, and iterate until tests pass.
- Implement ALL required changes; do not stop with a partial implementation.
- Stay within the file scope described in the task. Do not edit infra/CI/.git.
- When the tests pass and the task is complete, stop and give a short summary.
"""


def build_model(tier: str):
    """tier in {'nex','claude'}. Returns an AgentScope ChatModel or None."""
    from agentscope.formatter import AnthropicChatFormatter, OpenAIChatFormatter
    from agentscope.model import AnthropicChatModel, OpenAIChatModel
    from agentscope.credential import AnthropicCredential, OpenAICredential

    if tier == "nex":
        key = os.environ.get("OPENROUTER_API_KEY")
        if not key:
            return None
        return OpenAIChatModel(
            credential=OpenAICredential(
                api_key=key,
                base_url=os.environ.get("NEX_BASE_URL", "https://openrouter.ai/api/v1"),
            ),
            model=os.environ.get("NEX_MODEL", "nex-agi/nex-n2-pro:free"),
            stream=False,
            formatter=OpenAIChatFormatter(),
        )
    if tier == "claude":
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            return None
        return AnthropicChatModel(
            credential=AnthropicCredential(api_key=key),
            model=os.environ.get("CLAUDE_MODEL", "claude-opus-4-8"),
            stream=False,
            formatter=AnthropicChatFormatter(),
        )
    return None


async def run_agent(tier: str, worktree: str, task: str, max_iters: int) -> bool:
    """Run one AgentScope ReAct agent pass. Returns True if it completed without error."""
    from agentscope.agent import Agent, ReActConfig
    from agentscope.message import Msg, TextBlock
    from agentscope.permission import PermissionContext, PermissionMode
    from agentscope.state import AgentState
    from agentscope.tool import Bash, Edit, Grep, Read, Toolkit, Write

    model = build_model(tier)
    if model is None:
        log(f"tier '{tier}' unavailable (missing key)")
        return False

    root = os.path.abspath(worktree)
    toolkit = Toolkit(tools=[Bash(cwd=root), Read(), Write(), Edit(), Grep()])
    # BYPASS: headless autonomous run — no human to answer per-tool confirmations.
    state = AgentState(
        permission_context=PermissionContext(mode=PermissionMode.BYPASS)
    )
    agent = Agent(
        name=f"loop-engineer-{tier}",
        system_prompt=SYS_PROMPT_TMPL.format(root=root),
        model=model,
        toolkit=toolkit,
        state=state,
        react_config=ReActConfig(max_iters=max_iters),
    )
    log(f"running tier '{tier}' agent (max_iters={max_iters})")
    # Keep stdout clean for the final JSON: agent chatter goes to stderr.
    msg = Msg(name="user", content=[TextBlock(type="text", text=task)], role="user")
    with redirect_stdout(sys.stderr):
        await agent.reply(msg)
    return True


def claude_cli_tier(worktree: str, task: str) -> bool:
    """Fallback Claude tier via the authenticated `claude` CLI.

    Opt-in only: this spawns an autonomous `claude -p --dangerously-skip-permissions`
    loop, so it stays disabled unless CLAUDE_CLI_FALLBACK=1 is set explicitly.
    Prefer the Anthropic API path (set ANTHROPIC_API_KEY) for escalation.
    """
    from shutil import which

    if os.environ.get("CLAUDE_CLI_FALLBACK") != "1":
        log("Claude CLI fallback disabled (set CLAUDE_CLI_FALLBACK=1 to enable); "
            "no ANTHROPIC_API_KEY means no escalation this run")
        return False
    if not which("claude"):
        log("claude CLI not found; cannot escalate")
        return False
    log("escalating to Claude via `claude -p` CLI")
    code, out = run(
        ["claude", "-p", task, "--dangerously-skip-permissions"],
        worktree,
        timeout=1200,
    )
    sys.stderr.write(out[-2000:] + "\n")
    return code == 0


async def main() -> int:
    if len(sys.argv) < 2:
        print(json.dumps({"status": "blocked", "summary": "usage: <worktree> [taskfile]",
                          "files_changed": [], "model": None, "iters": 0}))
        return 0
    worktree = sys.argv[1]
    taskfile = sys.argv[2] if len(sys.argv) > 2 else os.path.join(worktree, "task.md")
    if not Path(taskfile).exists():
        print(json.dumps({"status": "blocked", "summary": f"taskfile not found: {taskfile}",
                          "files_changed": [], "model": None, "iters": 0}))
        return 0

    task = Path(taskfile).read_text(errors="ignore")
    test_cmd = resolve_test_cmd(worktree)
    max_iters = int(os.environ.get("MAX_ITERS", "18"))
    os.chdir(worktree)

    # Tier 1: Nex-V2-Pro
    ran = await run_agent("nex", worktree, task, max_iters)
    if ran:
        ok, tail = test_passes(worktree, test_cmd)
        if ok and changed_files(worktree):
            print(json.dumps({"status": "done", "summary": "tests pass (Nex-V2-Pro)",
                              "files_changed": changed_files(worktree),
                              "model": "nex-v2-pro", "iters": max_iters}))
            return 0
        log("Nex tier did not satisfy the test gate; escalating to Claude")
        escalation_task = task + (
            "\n\n--- PREVIOUS ATTEMPT (Nex-V2-Pro) FAILED THE TEST GATE ---\n"
            f"Test command: {test_cmd}\nLast test output:\n{tail}\n"
            "Fix the implementation so the tests pass."
        )
    else:
        log("Nex tier failed to run; escalating to Claude")
        escalation_task = task

    # Tier 2: Claude Opus 4.8 (API if available, else CLI)
    used_cli = False
    if os.environ.get("ANTHROPIC_API_KEY"):
        await run_agent("claude", worktree, escalation_task, max_iters)
    else:
        used_cli = claude_cli_tier(worktree, escalation_task)

    ok, tail = test_passes(worktree, test_cmd)
    if ok and changed_files(worktree):
        print(json.dumps({"status": "done", "summary": "tests pass (Claude Opus 4.8)",
                          "files_changed": changed_files(worktree),
                          "model": "claude-opus-4-8" + ("-cli" if used_cli else ""),
                          "iters": max_iters}))
        return 0

    print(json.dumps({"status": "blocked",
                      "summary": "both tiers failed the test gate",
                      "files_changed": changed_files(worktree),
                      "model": None, "iters": max_iters}))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
