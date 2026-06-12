#!/usr/bin/env bash
# One-time bootstrap for the Mac Mini M1 orchestrator.
# Run once after a fresh macOS install or when setting up a new M1.
# Idempotent — safe to re-run.

set -euo pipefail

log() { echo "[bootstrap] $*"; }

# ── dependencies ──────────────────────────────────────────────────────────────

log "Installing dependencies via Homebrew…"
brew install gh git jq tailscale block/tap/goose 2>/dev/null || true

# ── GitHub CLI auth ───────────────────────────────────────────────────────────

if ! gh auth status &>/dev/null; then
  log "gh not authenticated — run: gh auth login"
  echo "After logging in, re-run this script."
  exit 1
fi
log "gh auth: OK ($(gh auth status 2>&1 | grep 'Logged in' || true))"

# ── SSH key for M1 → RTX ─────────────────────────────────────────────────────

SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
  log "Generating SSH key…"
  ssh-keygen -t ed25519 -C "goose-orchestrator@mac-mini" -f "$SSH_KEY" -N ""
fi
log "SSH pubkey: $(cat ${SSH_KEY}.pub)"
log "Add the above to authorized_keys on the RTX server (milai), then run:"
log "  ssh-keyscan milai >> ~/.ssh/known_hosts"

# ── Goose config ──────────────────────────────────────────────────────────────

GOOSE_CONF="$HOME/.config/goose/config.yaml"
if [[ ! -f "$GOOSE_CONF" ]]; then
  mkdir -p "$(dirname "$GOOSE_CONF")"
  cp "$(dirname "$0")/goose-config.yaml.template" "$GOOSE_CONF"
  log "Goose config written to $GOOSE_CONF — review and adjust if needed."
else
  log "Goose config already exists at $GOOSE_CONF"
fi

# ── launchd plists ────────────────────────────────────────────────────────────

for PLIST_NAME in com.logan.goose-scheduler.plist com.logan.goose-nightly.plist; do
  PLIST_SRC="$(dirname "$0")/${PLIST_NAME}"
  PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_NAME}"
  if [[ ! -f "$PLIST_DST" ]]; then
    cp "$PLIST_SRC" "$PLIST_DST"
    log "Launchd plist installed: $PLIST_DST"
  else
    log "Launchd plist already at: $PLIST_DST"
  fi
done
log "Load with: launchctl load ~/Library/LaunchAgents/com.logan.goose-scheduler.plist"
log "           launchctl load ~/Library/LaunchAgents/com.logan.goose-nightly.plist"

# ── clone platform repo ───────────────────────────────────────────────────────

PLATFORM_DIR="$HOME/agentic-platform"
if [[ ! -d "$PLATFORM_DIR" ]]; then
  log "Cloning agentic-platform repo…"
  gh repo clone namlogan/agentic-platform "$PLATFORM_DIR"
fi

log ""
log "Bootstrap complete. Next steps:"
log "  1. Add SSH pubkey (above) to RTX server authorized_keys"
log "  2. Run: ssh-keyscan milai >> ~/.ssh/known_hosts"
log "  3. Test: ssh milai 'hostname'"
log "  4. Load launchd agents:"
log "       launchctl load ~/Library/LaunchAgents/com.logan.goose-scheduler.plist"
log "       launchctl load ~/Library/LaunchAgents/com.logan.goose-nightly.plist"
log "  5. Verify: launchctl list | grep goose"
log "  6. Kill switch: launchctl unload ~/Library/LaunchAgents/com.logan.goose-scheduler.plist"
