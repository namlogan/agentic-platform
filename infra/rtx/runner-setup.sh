#!/usr/bin/env bash
# Register a self-hosted GitHub Actions runner on the RTX server.
# Run once as a non-root user that has docker access.
# Usage: GITHUB_TOKEN=<PAT> GITHUB_REPO=namlogan/agentic-platform ./runner-setup.sh

set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN required (fine-grained PAT, actions:write)}"
GITHUB_REPO="${GITHUB_REPO:?GITHUB_REPO required (owner/repo)}"
RUNNER_VERSION="2.317.0"  # pin; update monthly
RUNNER_LABEL="rtx5090"
RUNNER_DIR="$HOME/actions-runner"

echo "=== Installing GitHub Actions runner ==="

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Download runner.
ARCH="linux-x64"
curl -sLO "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${ARCH}-${RUNNER_VERSION}.tar.gz"
tar xzf "actions-runner-${ARCH}-${RUNNER_VERSION}.tar.gz"
rm "actions-runner-${ARCH}-${RUNNER_VERSION}.tar.gz"

# Obtain registration token.
REG_TOKEN=$(curl -sf \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token" \
  | jq -r '.token')

# Configure.
./config.sh \
  --url "https://github.com/${GITHUB_REPO}" \
  --token "$REG_TOKEN" \
  --name "$(hostname)-rtx5090" \
  --labels "$RUNNER_LABEL" \
  --unattended \
  --replace

# Install as systemd service.
sudo ./svc.sh install
sudo ./svc.sh start

echo "=== Runner installed and started ==="
echo "Verify: gh api repos/${GITHUB_REPO}/actions/runners"
