# kahu-stack-rs

Deployment stack for the KAHU vessel radar pipeline on Raspberry Pi.

Installs and manages two services:
- **mayara-server** — interfaces with the Navico/Halo radar over UDP
- **kahu-daemon** — detects targets, tracks vessels, uploads to [crowdsource.kahu.earth](https://crowdsource.kahu.earth)

## Requirements

- Raspberry Pi running Ubuntu 24.04 LTS (aarch64)
- Navico/Halo radar connected via ethernet
- KAHU API key from [crowdsource.kahu.earth/my-vessels](https://crowdsource.kahu.earth/my-vessels)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/KAHU-radar/kahu-stack-rs/main/install.sh | bash
```

Or with arguments (no prompts):

```bash
curl -fsSL https://raw.githubusercontent.com/KAHU-radar/kahu-stack-rs/main/install.sh \
  | bash -s -- --api-key <your-api-key> --interface eth0
```

The installer will:
1. Download `kahu-daemon` and `mayara-server` binaries
2. Install systemd services for both
3. Auto-detect the radar ID from the connected hardware
4. Start both services immediately

## Configuration

All settings live in `/etc/default/kahu`:

```bash
KAHU_API_KEY=your-api-key-here
RADAR_INTERFACE=eth0        # network interface the radar is connected to
RADAR_ID=nav1034A           # auto-detected during install; change if needed
```

After editing, restart with:

```bash
sudo systemctl restart mayara-server kahu-daemon
```

## Status and logs

```bash
sudo systemctl status mayara-server kahu-daemon
sudo journalctl -fu kahu-daemon
sudo journalctl -fu mayara-server
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/KAHU-radar/kahu-stack-rs/main/uninstall.sh | bash
```

## Architecture

```
[Navico/Halo Radar]
    | UDP multicast (Navico protocol)
    v
mayara-server          — discovers radar, exposes spoke WebSocket on :6502
    | ws://localhost:6502/signalk/v2/api/vessels/self/radars/<id>/spokes
    v
kahu-daemon            — threshold detection → DBSCAN → Kalman tracking
    | Avro/TCP
    v
crowdsource.kahu.earth:9900  — TrackServer cloud backend
```

## Components

| Component | Source |
|---|---|
| `kahu-daemon` | [KAHU-radar/kahu-vessel-rs](https://github.com/KAHU-radar/kahu-vessel-rs) |
| `mayara-server` | [MarineYachtRadar/mayara-server](https://github.com/MarineYachtRadar/mayara-server) |

## Uninstall

```bash
bash uninstall.sh
```
