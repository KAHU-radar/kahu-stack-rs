#!/usr/bin/env bash
# KAHU Stack uninstaller

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[kahu]${NC} $*"; }
error() { echo -e "${RED}[kahu]${NC} $*" >&2; exit 1; }

command -v sudo >/dev/null || error "sudo is required"

read -rp "This will stop and remove the KAHU stack. Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

info "Stopping services..."
sudo systemctl stop  kahu-daemon    2>/dev/null || true
sudo systemctl stop  mayara-server  2>/dev/null || true
sudo systemctl disable kahu-daemon    2>/dev/null || true
sudo systemctl disable mayara-server  2>/dev/null || true

info "Removing service files..."
sudo rm -f /etc/systemd/system/kahu-daemon.service
sudo rm -f /etc/systemd/system/mayara-server.service
sudo systemctl daemon-reload

info "Removing binaries..."
sudo rm -f /usr/local/bin/kahu-daemon
sudo rm -f /usr/local/bin/mayara-server

info "Removing config..."
sudo rm -f /etc/default/kahu
sudo rm -f /etc/netplan/99-kahu-radar.yaml
# Note: intentionally not running netplan apply — it can disrupt WiFi.

info "Done. Logs are still available via: journalctl -u kahu-daemon"
