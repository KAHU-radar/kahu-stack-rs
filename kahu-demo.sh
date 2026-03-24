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
MIN_FIXES=2
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
KAHU_API_KEY=$(grep -E '^KAHU_API_KEY=' "$KAHU_ENV" | cut -d= -f2-)
[[ -n "$KAHU_API_KEY" ]] || error "KAHU_API_KEY not set in $KAHU_ENV"
command -v tcpreplay >/dev/null || error "tcpreplay not installed (sudo apt-get install -y tcpreplay)"

# ── Cleanup on exit / Ctrl-C ─────────────────────────────────────────────────
MAYARA_PID=""
DAEMON_PID=""
cleanup() {
    echo ""
    info "Stopping..."
    [[ -n "$DAEMON_PID" ]] && kill -INT "$DAEMON_PID" 2>/dev/null || true
    sleep 2
    [[ -n "$DAEMON_PID" ]] && kill -9   "$DAEMON_PID" 2>/dev/null || true
    [[ -n "$MAYARA_PID" ]] && kill -9   "$MAYARA_PID" 2>/dev/null || true
    info "Done."
}
trap cleanup EXIT INT TERM

# ── Preflight: clear any stale processes from previous runs ──────────────────
pkill -f mayara-server 2>/dev/null || true
pkill -f kahu-daemon   2>/dev/null || true
sleep 1

# ── 1. Start mayara ──────────────────────────────────────────────────────────
info "Starting mayara-server (logs → /tmp/mayara-demo.log)..."
/usr/local/bin/mayara-server \
    --interface lo --brand navico \
    --replay --nmea0183 --navigation-address udp:0.0.0.0:10110 \
    > /tmp/mayara-demo.log 2>&1 &
MAYARA_PID=$!

info "Waiting for mayara to start..."
for i in $(seq 1 20); do
    if curl -s --max-time 1 -o /dev/null http://localhost:6502/ 2>/dev/null; then
        break
    fi
    if ! kill -0 "$MAYARA_PID" 2>/dev/null; then
        error "mayara crashed — check /tmp/mayara-demo.log"
    fi
    sleep 1
done

# ── 2. Warm up radar — seed discovery AND GPS position before connecting daemon
# Pass 1 (full speed): seeds radar UDP discovery and delivers NMEA/GPS data.
# The NMEA sentence is ~4-5 s into the pcap; at full speed this arrives almost
# immediately, so mayara caches the vessel position before Pass 2 begins.
tcpreplay -t -i lo "$PCAP" > /dev/null 2>&1

# Poll until mayara registers the radar (WebSocket endpoint becomes valid).
info "Waiting for radar to come online..."
for i in $(seq 1 20); do
    if curl -sf http://localhost:6502/signalk/v2/api/vessels/self/radars 2>/dev/null \
            | grep -q 'spokeDataUrl'; then
        info "Radar online"
        break
    fi
    if ! kill -0 "$MAYARA_PID" 2>/dev/null; then
        error "mayara crashed — check /tmp/mayara-demo.log"
    fi
    sleep 1
done

# ── 3. Start kahu-daemon ─────────────────────────────────────────────────────
info "Starting kahu-daemon..."
RUST_LOG=kahu_daemon=info /usr/local/bin/kahu-daemon \
    --ws-url "ws://localhost:6502/signalk/v2/api/vessels/self/radars/${RADAR_ID}/spokes" \
    --api-key "$KAHU_API_KEY" \
    --land-filter \
    --spoke-timeout "$SPOKE_TIMEOUT" \
    --min-fixes "$MIN_FIXES" \
    --startup-delay 0 &
DAEMON_PID=$!

info "Waiting for daemon to connect (3s)..."
sleep 3

# ── 4. Stream radar data through the pipeline ─────────────────────────────────
# Pass 2a (full speed): re-seeds GPS in mayara immediately before the slow
# replay.  mayara resets its GPS state when the UDP stream restarts, so the
# NMEA from Pass 1 is stale by the time we reach here.  This mini-pass
# ensures the position is fresh (< 100 ms old) when Pass 2b begins, so
# kahu-daemon sees lat/lon in every spoke from the very first frame.
info "Re-seeding GPS position..."
tcpreplay -t -i lo "$PCAP" > /dev/null 2>&1

# Pass 2b (slow): full spoke data at 1/5th speed (~30s).  GPS is now
# already cached in mayara so kahu-daemon has valid position from spoke 1.
info "Streaming radar data..."
tcpreplay --multiplier 0.2 -i lo "$PCAP" > /dev/null 2>&1

# ── 5. Wait for spoke timeout to fire, flush, and upload ──────────────────────
info "Data complete — waiting ${SPOKE_TIMEOUT}s for tracks to upload..."
sleep $((SPOKE_TIMEOUT + 5))

info "Tracks uploaded — shutting down"
# cleanup trap fires here
