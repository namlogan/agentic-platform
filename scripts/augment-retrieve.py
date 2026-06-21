#!/usr/bin/env python3
"""augment-retrieve.py — one-shot Augment Context Engine retrieval over stdio MCP.

Spawns `auggie --mcp` (Augment's MCP tool server; its `codebase-retrieval` tool is
NOT account-gated, unlike `auggie -p`), runs the MCP handshake, calls
`codebase-retrieval` with an information_request, and prints the retrieved context
to stdout. Used by the role-split pipeline to feed the coder real codebase context.

Usage:
  augment-retrieve.py "information request"        # query as arg
  echo "request" | augment-retrieve.py             # or on stdin
Env:
  AUGGIE_BIN     path to auggie (default: auggie on PATH)
  AUGMENT_TIMEOUT  seconds before giving up (default: 60)
  AUGMENT_CWD    working dir to index (default: current dir)

Exit 0 with context on stdout; exit 1 (empty stdout) on any failure so callers can
degrade gracefully to "no context".
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time


def log(*a: object) -> None:
    print("[augment-retrieve]", *a, file=sys.stderr)


def main() -> int:
    req = " ".join(sys.argv[1:]).strip()
    if not req and not sys.stdin.isatty():
        req = sys.stdin.read().strip()
    if not req:
        log("no information_request provided")
        return 1

    auggie = os.environ.get("AUGGIE_BIN") or shutil.which("auggie")
    if not auggie:
        log("auggie not found")
        return 1
    timeout = float(os.environ.get("AUGMENT_TIMEOUT", "60"))
    cwd = os.environ.get("AUGMENT_CWD") or os.getcwd()

    try:
        proc = subprocess.Popen(
            [auggie, "--mcp"],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except Exception as e:  # noqa: BLE001
        log(f"failed to start auggie --mcp: {e}")
        return 1

    def send(obj: dict) -> None:
        assert proc.stdin
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    # Collect responses on a background thread so we can enforce a hard deadline.
    responses: dict[int, dict] = {}
    done = threading.Event()

    def reader() -> None:
        assert proc.stdout
        for line in proc.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue  # skip the server's banner chatter
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(msg.get("id"), int):
                responses[msg["id"]] = msg
                if msg["id"] == 2:
                    done.set()
                    return

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                         "clientInfo": {"name": "augment-retrieve", "version": "1"}}})
        # wait briefly for init before notifying/initialized + calling the tool
        deadline = time.time() + timeout
        while 1 not in responses and time.time() < deadline:
            time.sleep(0.05)
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": "codebase-retrieval",
                         "arguments": {"information_request": req}}})
        done.wait(timeout=max(1.0, deadline - time.time()))
    finally:
        try:
            proc.terminate()
        except Exception:  # noqa: BLE001
            pass

    msg = responses.get(2)
    if not msg or "result" not in msg:
        log("no retrieval result (timeout or error)")
        return 1
    parts = []
    for block in msg["result"].get("content", []):
        if block.get("type") == "text" and block.get("text"):
            parts.append(block["text"])
    text = "\n".join(parts).strip()
    if not text:
        log("empty retrieval result")
        return 1
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
