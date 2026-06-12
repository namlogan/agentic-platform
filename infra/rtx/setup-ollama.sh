#!/usr/bin/env bash
# Setup Ollama on the RTX 5090 server (alternative to vLLM — simpler, no Docker required).
# Run this on the RTX server as the milai user.
# Usage: bash setup-ollama.sh

set -euo pipefail

echo "=== Ollama Setup on RTX 5090 ==="

if [[ "$(hostname)" != "milai" ]]; then
  echo "ERROR: Run on milai (RTX server)."
  exit 1
fi

# Install Ollama
if ! command -v ollama &>/dev/null; then
  echo "[1/5] Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "[1/5] Ollama already installed: $(ollama --version)"
fi

# Expose on all interfaces (needed for Tailscale access from M1)
echo "[2/5] Configuring Ollama to bind on all interfaces..."
SVCFILE="/etc/systemd/system/ollama.service"
if ! grep -q "OLLAMA_HOST" "$SVCFILE" 2>/dev/null; then
  sudo sed -i '/\[Service\]/a Environment="OLLAMA_HOST=0.0.0.0"' "$SVCFILE"
  sudo systemctl daemon-reload
  sudo systemctl restart ollama
fi
echo "✓ OLLAMA_HOST=0.0.0.0 set"

# Pull models
echo "[3/5] Pulling models..."
echo "  → qwen2.5:7b (orchestrator brain, ~4.7 GB)..."
ollama pull qwen2.5:7b

echo "  → qwen2.5-coder:14b (LLM code review in verify.sh, ~9 GB)..."
ollama pull qwen2.5-coder:14b

echo "[4/5] Verifying models..."
ollama list

# Smoke test
echo "[5/5] Smoke test..."
python3 -c "
import json, urllib.request, time

url = 'http://localhost:11434/api/generate'
data = json.dumps({'model': 'qwen2.5:7b', 'prompt': 'Say hello', 'stream': False}).encode()
t0 = time.time()
req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
with urllib.request.urlopen(req) as r:
    resp = json.load(r)
elapsed = time.time() - t0
tokens = resp.get('eval_count', 0)
tok_s = round(tokens / (resp.get('eval_duration', 1) / 1e9), 1)
print(f'PASS: {tok_s} tok/s (target: ≥20)')
assert tok_s >= 20, f'FAIL: only {tok_s} tok/s'
"

echo ""
echo "=== Ollama setup complete ==="
echo "Endpoint: http://\$(hostname -I | awk '{print \$1}'):11434"
echo "Test from M1: curl http://milai:11434/api/tags"
