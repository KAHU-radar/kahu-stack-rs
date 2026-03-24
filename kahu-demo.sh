#!/usr/bin/env bash
# KAHU demo — runs mayara + kahu-daemon directly (no systemd required)
#
# Usage (run as root or with sudo):
#   sudo kahu-demo --data halo_and_0183.pcap
#   sudo kahu-demo --data /path/to/halo_and_0183.pcap
#
# Download pcap:
#   curl -fL https://raw.githubusercontent.com/MarineYachtRadar/mayara-server/main/demo/samples/halo_and_0183.pcap \
#        -o halo_and_0183.pcap

set -euo pipefail

KAHU_ENV="/etc/default/kahu"
SPOKE_TIMEOUT=15
MIN_FIXES=1
RADAR_ID="${RADAR_ID:-nav1034A}"
PCAP=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[demo]${NC} $*"; }
warn()  { echo -e "${YELLOW}[demo]${NC} $*"; }
error() { echo -e "${RED}[demo]${NC} $*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data) PCAP="$2"; shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# Resolve relative paths against the caller's working directory
[[ -n "$PCAP" ]] || error "--data <pcap> is required"
[[ "$PCAP" = /* ]] || PCAP="$(pwd)/$PCAP"
[[ -f "$PCAP" ]] || error "pcap not found: $PCAP"

# ── Load config ──────────────────────────────────────────────────────────────
[[ -f "$KAHU_ENV" ]] || error "$KAHU_ENV not found — run install.sh first"
# shellcheck source=/dev/null
source "$KAHU_ENV"
[[ -n "${KAHU_API_KEY:-}" ]] || error "KAHU_API_KEY not set in $KAHU_ENV"
command -v tcpreplay >/dev/null || error "tcpreplay not installed (sudo apt-get install -y tcpreplay)"

# ── Cleanup on exit / Ctrl-C ─────────────────────────────────────────────────
MAYARA_PID=""
DAEMON_PID=""
cleanup() {
    echo ""
    info "Stopping..."
    [[ -n "$DAEMON_PID" ]] && kill -INT "$DAEMON_PID" 2>/dev/null || true
    [[ -n "$MAYARA_PID" ]] && kill      "$MAYARA_PID" 2>/dev/null || true
    [[ -n "$DAEMON_PID" ]] && wait      "$DAEMON_PID" 2>/dev/null || true
    info "Done."
}
trap cleanup EXIT INT TERM

# ── 1. Start mayara ──────────────────────────────────────────────────────────
info "Starting mayara-server (logs → /tmp/mayara-demo.log)..."
RUST_MIN_STACK=8388608 /usr/local/bin/mayara-server \
    --interface lo --brand navico \
    --replay --nmea0183 --navigation-address udp:0.0.0.0:10110 \
    > /tmp/mayara-demo.log 2>&1 &
MAYARA_PID=$!

info "Waiting for mayara WebSocket..."
for i in $(seq 1 20); do
    if curl -s --max-time 1 -o /dev/null http://localhost:6502/ 2>/dev/null; then
        info "mayara ready"
        break
    fi
    if ! kill -0 "$MAYARA_PID" 2>/dev/null; then
        error "mayara crashed — check /tmp/mayara-demo.log"
    fi
    sleep 1
done

# ── 2. Start kahu-daemon ─────────────────────────────────────────────────────
info "Starting kahu-daemon..."
RUST_LOG=warn /usr/local/bin/kahu-daemon \
    --ws-url "ws://localhost:6502/signalk/v2/api/vessels/self/radars/${RADAR_ID}/spokes" \
    --api-key "$KAHU_API_KEY" \
    --land-filter \
    --spoke-timeout "$SPOKE_TIMEOUT" \
    --min-fixes "$MIN_FIXES" \
    --startup-delay 0 &
DAEMON_PID=$!

info "Waiting for daemon to connect to mayara (3s)..."
sleep 3

# ── 3. Replay pcap ───────────────────────────────────────────────────────────
info "Replaying $PCAP..."
tcpreplay -t -i lo "$PCAP"
info "Pcap complete — waiting ${SPOKE_TIMEOUT}s for tracks to flush and upload..."

# ── 4. Wait for spoke timeout + upload buffer ─────────────────────────────────
sleep $((SPOKE_TIMEOUT + 10))

info "Tracks uploaded — shutting down"
# cleanup trap fires here
