#!/usr/bin/env bash
# KAHU Stack installer — Raspberry Pi (aarch64, Ubuntu 24.04 LTS)
#
# Production (real Navico hardware):
#   bash install.sh --api-key <key> [--interface <iface>]
#
# Demo (pcap replay, no hardware needed):
#   bash install.sh --api-key <key> --demo
#
# Interactive (prompts for missing values):
#   bash install.sh

set -euo pipefail

KAHU_VESSEL_RS_REPO="KAHU-radar/kahu-vessel-rs"
KAHU_STACK_RS_REPO="KAHU-radar/kahu-stack-rs"
MAYARA_REPO="MarineYachtRadar/mayara-server"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
KAHU_ENV="/etc/default/kahu"
RAW_BASE="https://raw.githubusercontent.com/$KAHU_STACK_RS_REPO/main"
DEMO_PCAP_URL="https://raw.githubusercontent.com/$MAYARA_REPO/main/demo/samples/halo_and_0183.pcap"
DEMO_PCAP_PATH="/tmp/halo_and_0183.pcap"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[kahu]${NC} $*"; }
warn()  { echo -e "${YELLOW}[kahu]${NC} $*"; }
error() { echo -e "${RED}[kahu]${NC} $*" >&2; exit 1; }

# ── Parse arguments ────────────────────────────────────────────────────────────
API_KEY=""
RADAR_INTERFACE=""
DEMO=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)   API_KEY="$2";         shift 2 ;;
        --interface) RADAR_INTERFACE="$2"; shift 2 ;;
        --demo)      DEMO=true;            shift   ;;
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
if [[ "$DEMO" == "true" ]]; then
    echo "  Vessel Radar Stack Installer  [DEMO MODE]"
else
    echo "  Vessel Radar Stack Installer"
fi
echo ""

# ── Prompt for API key ─────────────────────────────────────────────────────────
if [[ -z "$API_KEY" ]]; then
    echo "  Get your API key at: https://crowdsource.kahu.earth/my-vessels"
    echo ""
    read -rp "  API key: " API_KEY
    [[ -n "$API_KEY" ]] || error "API key is required"
fi

# ── Radar interface ────────────────────────────────────────────────────────────
if [[ "$DEMO" == "true" ]]; then
    RADAR_INTERFACE=lo
    info "Demo mode: using loopback interface (pcap replay)"
elif [[ -z "$RADAR_INTERFACE" ]]; then
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
# Pinned to a known-good gnu build (MarineYachtRadar/mayara-server @ 55af4c5).
# The official v3.0.0 musl release has a stack overflow bug in the Locator
# subsystem. Switch back to the official release once that is fixed upstream.
# Tracked: https://github.com/MarineYachtRadar/mayara-server/issues/23
info "Downloading mayara-server..."
curl -fL "https://github.com/$KAHU_STACK_RS_REPO/releases/latest/download/mayara-server-aarch64-linux" \
    -o /tmp/mayara-server \
    || error "Could not download mayara-server. Check https://github.com/$KAHU_STACK_RS_REPO/releases"
sudo install -m 755 /tmp/mayara-server "$INSTALL_DIR/mayara-server"
info "  mayara-server → $INSTALL_DIR/mayara-server"

# ── Install systemd services ───────────────────────────────────────────────────
info "Installing systemd services..."
curl -fL "$RAW_BASE/systemd/mayara-server.service" -o /tmp/mayara-server.service
curl -fL "$RAW_BASE/systemd/kahu-daemon.service"   -o /tmp/kahu-daemon.service
sudo install -m 644 /tmp/mayara-server.service "$SYSTEMD_DIR/mayara-server.service"
sudo install -m 644 /tmp/kahu-daemon.service   "$SYSTEMD_DIR/kahu-daemon.service"

# ── Static IP on radar interface (production only) ─────────────────────────────
# Navico/Halo radars don't run DHCP — the interface needs a static IP.
# Skipped in demo mode since loopback already has 127.0.0.1.
if [[ "$DEMO" == "false" ]]; then
    IFACE_HAS_IP=$(ip -4 addr show "$RADAR_INTERFACE" 2>/dev/null | grep -c 'inet ' || true)
    if [[ "$IFACE_HAS_IP" -eq 0 ]]; then
        info "Configuring static IP 192.168.0.100/24 on $RADAR_INTERFACE..."
        sudo ip addr add 192.168.0.100/24 dev "$RADAR_INTERFACE" 2>/dev/null || true
        sudo ip link set "$RADAR_INTERFACE" up
        NETPLAN_FILE="/etc/netplan/99-kahu-radar.yaml"
        sudo tee "$NETPLAN_FILE" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    ${RADAR_INTERFACE}:
      addresses: [192.168.0.100/24]
      dhcp4: false
EOF
        sudo chmod 600 "$NETPLAN_FILE"
        info "  $RADAR_INTERFACE → 192.168.0.100/24 (persists after reboot)"
    else
        info "  $RADAR_INTERFACE already has an IP — skipping static config"
    fi
fi

# ── Set radar ID ───────────────────────────────────────────────────────────────
# Default to nav1034A (Navico HALO 034). Edit /etc/default/kahu to change.
RADAR_ID="nav1034A"
info "Radar ID: $RADAR_ID (edit $KAHU_ENV to change if needed)"

# ── Write environment file ─────────────────────────────────────────────────────
info "Writing $KAHU_ENV..."
if [[ "$DEMO" == "true" ]]; then
    sudo tee "$KAHU_ENV" > /dev/null <<EOF
KAHU_API_KEY=$API_KEY
RADAR_INTERFACE=$RADAR_INTERFACE
RADAR_ID=$RADAR_ID
MAYARA_EXTRA_FLAGS=--replay --nmea0183 --navigation-address udp:0.0.0.0:10110
SPOKE_TIMEOUT=15
MIN_FIXES=1
EOF
else
    sudo tee "$KAHU_ENV" > /dev/null <<EOF
KAHU_API_KEY=$API_KEY
RADAR_INTERFACE=$RADAR_INTERFACE
RADAR_ID=$RADAR_ID
MAYARA_EXTRA_FLAGS=
SPOKE_TIMEOUT=60
MIN_FIXES=3
EOF
fi

# ── Demo extras: tcpreplay + pcap ─────────────────────────────────────────────
if [[ "$DEMO" == "true" ]]; then
    if ! command -v tcpreplay >/dev/null; then
        info "Installing tcpreplay..."
        sudo apt-get install -y tcpreplay > /dev/null
    fi
    info "Downloading demo pcap (3.8 MB)..."
    curl -fL "$DEMO_PCAP_URL" -o "$DEMO_PCAP_PATH" \
        || error "Could not download demo pcap from $DEMO_PCAP_URL"
    info "  pcap → $DEMO_PCAP_PATH"
fi

# ── Enable services ────────────────────────────────────────────────────────────
info "Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable mayara-server kahu-daemon

# Production: start immediately.
# Demo: services are enabled but not started — start them manually to show
# the pipeline coming up step by step (see instructions below).
if [[ "$DEMO" == "false" ]]; then
    # kahu-daemon uses --startup-delay 10 so it waits for mayara to detect the
    # radar before connecting.  mayara may take several seconds after startup
    # before the WebSocket spoke endpoint becomes available.
    sudo systemctl restart mayara-server
    sudo systemctl start kahu-daemon
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
info "Installation complete!"
echo ""

if [[ "$DEMO" == "true" ]]; then
    echo "  Run the demo pipeline in order:"
    echo ""
    echo "  1) Start the radar interface layer:"
    echo "       sudo systemctl start mayara-server"
    echo ""
    echo "  2) Start replaying radar data:"
    echo "       sudo tcpreplay -l 0 -i lo $DEMO_PCAP_PATH"
    echo ""
    echo "  3) Start the daemon  (will wait 10 s for mayara to initialise):"
    echo "       sudo systemctl start kahu-daemon"
    echo ""
    echo "  4) Watch the data flow:"
    echo "       sudo journalctl -fu kahu-daemon"
    echo ""
    echo "  Tracks will appear at https://crowdsource.kahu.earth (~3-4 min)"
    echo ""
else
    echo "  Status : sudo systemctl status mayara-server kahu-daemon"
    echo "  Logs   : sudo journalctl -fu kahu-daemon"
    echo "  Config : $KAHU_ENV"
    echo ""
    echo "  Vessel tracks will appear at https://crowdsource.kahu.earth"
    echo ""
fi
