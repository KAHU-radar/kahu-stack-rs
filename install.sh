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
MAYARA_REPO="MarineYachtRadar/mayara-server"
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
curl -fL "https://github.com/$KAHU_VESSEL_RS_REPO/releases/latest/download/kahu-daemon-aarch64-linux" \
    -o /tmp/kahu-daemon \
    || error "Could not download kahu-daemon. Check https://github.com/$KAHU_VESSEL_RS_REPO/releases"
sudo install -m 755 /tmp/kahu-daemon "$INSTALL_DIR/kahu-daemon"
info "  kahu-daemon → $INSTALL_DIR/kahu-daemon"

# ── Download mayara-server ─────────────────────────────────────────────────────
# Try the official mayara-server repo first; fall back to the bundled binary
# in kahu-stack-rs releases while the owner's release pipeline is being set up.
info "Downloading mayara-server..."
if curl -fL "https://github.com/$MAYARA_REPO/releases/latest/download/mayara-server-aarch64-linux" \
        -o /tmp/mayara-server 2>/dev/null; then
    info "  Using official mayara-server release"
else
    warn "Official mayara release not found — using bundled binary from kahu-stack-rs"
    curl -fL "https://github.com/$KAHU_STACK_RS_REPO/releases/latest/download/mayara-server-aarch64-linux" \
        -o /tmp/mayara-server \
        || error "Could not download mayara-server. Check https://github.com/$KAHU_STACK_RS_REPO/releases"
fi
sudo install -m 755 /tmp/mayara-server "$INSTALL_DIR/mayara-server"
info "  mayara-server → $INSTALL_DIR/mayara-server"

# ── Install systemd services ───────────────────────────────────────────────────
info "Installing systemd services..."
curl -fL "$RAW_BASE/systemd/mayara-server.service" -o /tmp/mayara-server.service
curl -fL "$RAW_BASE/systemd/kahu-daemon.service"   -o /tmp/kahu-daemon.service
sudo install -m 644 /tmp/mayara-server.service "$SYSTEMD_DIR/mayara-server.service"
sudo install -m 644 /tmp/kahu-daemon.service   "$SYSTEMD_DIR/kahu-daemon.service"

# ── Discover radar ID ──────────────────────────────────────────────────────────
# Run mayara directly (not via systemd) so we can discover the radar ID before
# writing the env file that the service depends on.
info "Starting mayara-server to discover radar ID..."
sudo RUST_MIN_STACK=8388608 "$INSTALL_DIR/mayara-server" \
    --interface "$RADAR_INTERFACE" --brand navico &
MAYARA_PID=$!
sleep 8

RADAR_ID=$(curl -sf "http://localhost:6502/signalk/v2/api/vessels/self/radars" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(iter(d)))" 2>/dev/null \
    || true)

sudo kill "$MAYARA_PID" 2>/dev/null || true
wait "$MAYARA_PID" 2>/dev/null || true

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
