#!/usr/bin/env bash
# KAHU demo — runs mayara + kahu-daemon directly (no systemd required)
#
# Loopback mode (default) — everything runs on this Pi:
#   sudo kahu-demo --data halo_and_0183.pcap
#   sudo kahu-demo --data halo_and_0183.pcap --loops 3
#
# Ethernet mode — Pi runs mayara + kahu-daemon; Mac streams the pcap:
#   sudo kahu-demo --interface eth0
#   (The script prints the tcpreplay command to run on the Mac.)
#
# --loops N       loopback only: replay the pcap N times (default 1).
#                 More loops give the land filter more data to warm up
#                 (suppresses dikes/coastlines) and produce longer tracks.
# --interface IF  network interface for mayara (default: lo).
#                 lo  = loopback, tcpreplay runs locally (--data required).
#                 eth0 = ethernet, tcpreplay runs on the Mac (no --data needed).

set -euo pipefail

KAHU_ENV="/etc/default/kahu"
SPOKE_TIMEOUT=15
MIN_FIXES=2
LOOPS=1
RADAR_ID="${RADAR_ID:-nav1034A}"
PCAP=""
INTERFACE="lo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[demo]${NC} $*"; }
warn()  { echo -e "${YELLOW}[demo]${NC} $*"; }
error() { echo -e "${RED}[demo]${NC} $*" >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data)      PCAP="$2";      shift 2 ;;
        --loops)     LOOPS="$2";     shift 2 ;;
        --interface) INTERFACE="$2"; shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# ── Mode-specific validation ──────────────────────────────────────────────────
if [[ "$INTERFACE" == "lo" ]]; then
    # Loopback: tcpreplay runs here, pcap must exist on this machine.
    [[ -n "$PCAP" ]] || error "--data <pcap> is required in loopback mode"
    [[ "$PCAP" = /* ]] || PCAP="$(pwd)/$PCAP"
    [[ -f "$PCAP" ]] || error "pcap not found: $PCAP"
    command -v tcpreplay >/dev/null || error "tcpreplay not installed (sudo apt-get install -y tcpreplay)"
else
    # Ethernet: tcpreplay runs on the Mac. --data and tcpreplay not needed here.
    [[ -z "$PCAP" ]] || warn "--data ignored in ethernet mode (pcap is replayed from the Mac)"
fi

# ── Load config ──────────────────────────────────────────────────────────────
[[ -f "$KAHU_ENV" ]] || error "$KAHU_ENV not found — run install.sh first"
KAHU_API_KEY=$(grep -E '^KAHU_API_KEY=' "$KAHU_ENV" | cut -d= -f2-)
[[ -n "$KAHU_API_KEY" ]] || error "KAHU_API_KEY not set in $KAHU_ENV"

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

# ── Preflight: stop systemd services then kill any stale processes ────────────
# pkill alone is not enough — systemd restarts killed processes after RestartSec,
# which can cause a second instance to race against the demo's own processes.
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop kahu-daemon mayara-server 2>/dev/null || true
fi
pkill -f mayara-server 2>/dev/null || true
pkill -f kahu-daemon   2>/dev/null || true
sleep 1

# ── 1. Start mayara ──────────────────────────────────────────────────────────
info "Starting mayara-server on $INTERFACE (logs → /tmp/mayara-demo.log)..."
/usr/local/bin/mayara-server \
    --interface "$INTERFACE" --brand navico \
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
# Give mayara time to bind its UDP multicast socket after the HTTP endpoint is up.
sleep 2

if [[ "$INTERFACE" == "lo" ]]; then
    # ── Loopback: seed radar discovery + GPS, then run pipeline locally ───────

    # Pass 1 (full speed): seeds radar UDP discovery and delivers NMEA/GPS data.
    tcpreplay -t -i lo "$PCAP" > /dev/null 2>&1

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

    # Re-seed GPS so position is fresh when kahu-daemon connects.
    info "Re-seeding GPS position..."
    tcpreplay -t -i lo "$PCAP" > /dev/null 2>&1

    # ── Start daemon ──────────────────────────────────────────────────────────
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

    # Loops run back-to-back so the land filter accumulates sweeps across all
    # loops.  More loops = better dike suppression and longer vessel tracks.
    for loop in $(seq 1 "$LOOPS"); do
        if [[ "$LOOPS" -gt 1 ]]; then
            info "Streaming radar data (loop $loop/$LOOPS)..."
        else
            info "Streaming radar data..."
        fi
        tcpreplay --multiplier 0.2 -i lo "$PCAP" > /dev/null 2>&1
    done

    info "Data complete — waiting ${SPOKE_TIMEOUT}s for tracks to upload..."
    sleep $((SPOKE_TIMEOUT + 5))

else
    # ── Ethernet: mayara listens on $INTERFACE; Mac streams the pcap ──────────
    #
    # tcpreplay sends raw Layer 2 frames — the Mac does not need a specific IP.
    # The Pi just needs an IP on $INTERFACE (any IP is fine for multicast).
    #
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    echo "  │  mayara is listening on $INTERFACE — now run these on your Mac:              │"
    echo "  │                                                                  │"
    echo "  │  1. Seed GPS + radar discovery (fast pass):                      │"
    echo "  │     sudo tcpreplay -t -i <mac-iface> halo_and_0183.pcap          │"
    echo "  │                                                                  │"
    echo "  │  2. Stream radar data (slow pass, repeat for more tracks):       │"
    echo "  │     sudo tcpreplay --multiplier 0.2 -i <mac-iface> halo_and_0183.pcap │"
    echo "  │                                                                  │"
    echo "  │  Replace <mac-iface> with your Mac's ethernet port (e.g. en9).   │"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    echo ""

    # Wait for the Mac's tcpreplay to bring the radar online.
    info "Waiting for radar data on $INTERFACE (run fast pass on Mac now)..."
    RADAR_UP=false
    for i in $(seq 1 60); do
        if curl -sf http://localhost:6502/signalk/v2/api/vessels/self/radars 2>/dev/null \
                | grep -q 'spokeDataUrl'; then
            info "Radar online"
            RADAR_UP=true
            break
        fi
        if ! kill -0 "$MAYARA_PID" 2>/dev/null; then
            error "mayara crashed — check /tmp/mayara-demo.log"
        fi
        sleep 1
    done
    [[ "$RADAR_UP" == "true" ]] || error "Radar not detected after 60s — is the Mac replaying on the right interface?"

    # ── Start daemon ──────────────────────────────────────────────────────────
    info "Starting kahu-daemon..."
    RUST_LOG=kahu_daemon=info /usr/local/bin/kahu-daemon \
        --ws-url "ws://localhost:6502/signalk/v2/api/vessels/self/radars/${RADAR_ID}/spokes" \
        --api-key "$KAHU_API_KEY" \
        --land-filter \
        --spoke-timeout "$SPOKE_TIMEOUT" \
        --min-fixes "$MIN_FIXES" \
        --startup-delay 0 &
    DAEMON_PID=$!

    echo ""
    info "Daemon running — now run the slow pass on the Mac:"
    echo ""
    echo "     sudo tcpreplay --multiplier 0.2 -i <mac-iface> halo_and_0183.pcap"
    echo ""
    info "Waiting ${SPOKE_TIMEOUT}s after data stops for tracks to upload..."

    # Hold until spoke timeout fires and daemon uploads, then cleanup trap runs.
    wait "$DAEMON_PID" 2>/dev/null || true
fi

info "Tracks uploaded — shutting down"
# cleanup trap fires here
