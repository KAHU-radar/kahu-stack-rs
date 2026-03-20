#!/usr/bin/env bash
# KAHU Stack installer — Raspberry Pi (aarch64, Ubuntu 24.04 LTS)
#
# Interactive:
#   bash install.sh
#
# Scripted (e.g. from a website "copy this command" flow):
#   bash install.sh --api-key <key> [--interface <iface>]

set -euo pipefail

KAHU_VESSEL_RS_REPO="KAHU-radar/kahu-vessel-rs"
KAHU_STACK_RS_REPO="KAHU-radar/kahu-stack-rs"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
KAHU_ENV="/etc/default/kahu"
RAW_BASE="https://raw.githubusercontent.com/$KAHU_STACK_RS_REPO/main"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[kahu]${NC} $*"; }
warn()  { echo -e "${YELLOW}[kahu]${NC} $*"; }
error() { echo -e "${RED}[kahu]${NC} $*" >&2; exit 1; }

# ── Parse arguments ────────────────────────────────────────────────────────────
API_KEY=""
RADAR_INTERFACE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)   API_KEY="$2";         shift 2 ;;
        --interface) RADAR_INTERFACE="$2"; shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# ── Preflight checks ───────────────────────────────────────────────────────────
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] || error "This installer only supports aarch64 (Raspberry Pi). Detected: $ARCH"
command -v curl  >/dev/null || error "curl is required. Run: sudo apt-get install -y curl"
command -v sudo  >/dev/null || error "sudo is required"

echo ""
echo "  ██╗  ██╗ █████╗ ██╗  ██╗██╗   ██╗"
echo "  ██║ ██╔╝██╔══██╗██║  ██║██║   ██║"
echo "  █████╔╝ ███████║███████║██║   ██║"
echo "  ██╔═██╗ ██╔══██║██╔══██║██║   ██║"
echo "  ██║  ██╗██║  ██║██║  ██║╚██████╔╝"
echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ "
echo ""
echo "  Vessel Radar Stack Installer"
echo ""

# ── Prompt for API key ─────────────────────────────────────────────────────────
if [[ -z "$API_KEY" ]]; then
    echo "  Get your API key at: https://crowdsource.kahu.earth/my-vessels"
    echo ""
    read -rp "  API key: " API_KEY
    [[ -n "$API_KEY" ]] || error "API key is required"
fi

# ── Prompt for radar interface ─────────────────────────────────────────────────
if [[ -z "$RADAR_INTERFACE" ]]; then
    echo ""
    echo "  Available network interfaces:"
    ip -br link show | awk '{printf "    %s\n", $1}'
    echo ""
    read -rp "  Radar interface [eth0]: " RADAR_INTERFACE
    RADAR_INTERFACE="${RADAR_INTERFACE:-eth0}"
fi

info "Starting installation"
info "  Interface : $RADAR_INTERFACE"
info "  API key   : ${API_KEY:0:8}..."
echo ""

# ── Download kahu-daemon ───────────────────────────────────────────────────────
info "Downloading kahu-daemon..."
DAEMON_URL=$(curl -sf "https://api.github.com/repos/$KAHU_VESSEL_RS_REPO/releases/latest" \
    | grep '"browser_download_url"' \
    | grep 'kahu-daemon-aarch64-linux' \
    | cut -d'"' -f4)
[[ -n "$DAEMON_URL" ]] || error "Could not find kahu-daemon release. Check https://github.com/$KAHU_VESSEL_RS_REPO/releases"
curl -fL "$DAEMON_URL" -o /tmp/kahu-daemon
sudo install -m 755 /tmp/kahu-daemon "$INSTALL_DIR/kahu-daemon"
info "  kahu-daemon → $INSTALL_DIR/kahu-daemon"

# ── Download mayara-server ─────────────────────────────────────────────────────
info "Downloading mayara-server..."
MAYARA_URL=$(curl -sf "https://api.github.com/repos/$KAHU_STACK_RS_REPO/releases/latest" \
    | grep '"browser_download_url"' \
    | grep 'mayara-server-aarch64-linux' \
    | cut -d'"' -f4)
[[ -n "$MAYARA_URL" ]] || error "Could not find mayara-server binary. Check https://github.com/$KAHU_STACK_RS_REPO/releases"
curl -fL "$MAYARA_URL" -o /tmp/mayara-server
sudo install -m 755 /tmp/mayara-server "$INSTALL_DIR/mayara-server"
info "  mayara-server → $INSTALL_DIR/mayara-server"

# ── Install systemd services ───────────────────────────────────────────────────
info "Installing systemd services..."
curl -fL "$RAW_BASE/systemd/mayara-server.service" -o /tmp/mayara-server.service
curl -fL "$RAW_BASE/systemd/kahu-daemon.service"   -o /tmp/kahu-daemon.service
sudo install -m 644 /tmp/mayara-server.service "$SYSTEMD_DIR/mayara-server.service"
sudo install -m 644 /tmp/kahu-daemon.service   "$SYSTEMD_DIR/kahu-daemon.service"

# ── Discover radar ID ──────────────────────────────────────────────────────────
info "Starting mayara-server to discover radar ID..."
sudo systemctl daemon-reload
sudo systemctl start mayara-server
sleep 8

RADAR_ID=$(curl -sf "http://localhost:6502/signalk/v2/api/vessels/self/radars" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(iter(d)))" 2>/dev/null \
    || true)

if [[ -n "$RADAR_ID" ]]; then
    info "  Radar detected: $RADAR_ID"
else
    warn "  Could not auto-detect radar ID — defaulting to 'nav1034A'"
    warn "  If your radar is not a HALO 034, edit RADAR_ID in $KAHU_ENV"
    RADAR_ID="nav1034A"
fi

# ── Write environment file ─────────────────────────────────────────────────────
info "Writing $KAHU_ENV..."
sudo tee "$KAHU_ENV" > /dev/null <<EOF
KAHU_API_KEY=$API_KEY
RADAR_INTERFACE=$RADAR_INTERFACE
RADAR_ID=$RADAR_ID
EOF

# ── Enable and start services ──────────────────────────────────────────────────
info "Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable mayara-server kahu-daemon
sudo systemctl restart mayara-server
sudo systemctl start kahu-daemon

echo ""
info "Installation complete!"
echo ""
echo "  Status : sudo systemctl status mayara-server kahu-daemon"
echo "  Logs   : sudo journalctl -fu kahu-daemon"
echo "  Config : $KAHU_ENV"
echo ""
echo "  Vessel tracks will appear at https://crowdsource.kahu.earth"
echo ""
