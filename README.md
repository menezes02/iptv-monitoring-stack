# Hotel IPTV Monitoring Stack

Production-grade monitoring for UDP multicast IPTV infrastructure, deployed in a single 8-hour engagement across a 200-device hotel installation.

## What it does

- Monitors UDP multicast streams (239.10.10.x:1234–1250) with per-stream metrics
- Detects packet loss, jitter, burst loss, and stream failures in real time
- Exposes all metrics to Prometheus, visualised in Grafana
- Produces a baseline audit report and case study with quantified findings

## Architecture

```
[IPTV Headend] → UDP Multicast → [Monitor Host]
                                       │
                                 Docker Compose:
                                 ├── Prometheus     :9090
                                 ├── Grafana        :3000
                                 ├── Node Exporter  :9100
                                 └── IPTV Exporter  :9200
```

## Metrics (per stream)

| Metric | Description |
|--------|-------------|
| `iptv_stream_bitrate_kbps` | Stream bitrate over 10s window |
| `iptv_stream_loss_percent` | RTP sequence-based packet loss % |
| `iptv_stream_jitter_ms` | Packet interarrival jitter (mean deviation) |
| `iptv_stream_burst_events_total` | Consecutive packet drop events (≥3 packets) |
| `iptv_stream_reorders_total` | Out-of-order packet arrivals |
| `iptv_stream_uptime_seconds` | Time since first packet on stream |
| `iptv_active_streams_total` | Count of active multicast streams |

## Alerts

- Stream packet loss >5% sustained for 1 minute
- Jitter >20ms sustained for 1 minute
- Burst loss events >2 per window
- All streams silent for 2 minutes
- Complete stream failure (100% loss for 30s)

## Quick Start

```bash
# Install dependencies
sudo apt-get install -y tcpdump ffmpeg docker.io docker-compose-v2

# Start monitoring stack
docker compose up -d

# Run baseline audit (Phase 1)
sudo ./scripts/01_baseline_scan.sh eth0 60

# Test IGMP snooping (run with 0 TVs active)
sudo ./scripts/05_igmp_test.sh eth0 30

# Get stream codec/resolution inventory
sudo ./scripts/04_ffprobe_inventory.sh eth0

# Generate case study report
./scripts/03_generate_cv_report.sh
```

## Dashboard

Open `http://localhost:3000` — login `admin / iptv2024`

![IPTV Stream Health Dashboard](reports/dashboard_screenshot.png)

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/iptv_exporter.py` | Custom Prometheus exporter |
| `scripts/mock_streams.py` | Simulate streams for testing |
| `scripts/01_baseline_scan.sh` | Phase 1 baseline audit |
| `scripts/04_ffprobe_inventory.sh` | Stream codec/resolution inventory |
| `scripts/05_igmp_test.sh` | IGMP snooping diagnostic |
| `scripts/02_stream_decoder_test.sh` | ffmpeg decode + bitrate stability |
| `scripts/03_generate_cv_report.sh` | Generate case study |

## Engagement Context

- **Site:** 200-room hotel, 200× Google TV devices
- **Constraint:** No switch/router admin access — passive monitoring only
- **Duration:** 8-hour single-day engagement
- **Outcome:** Zero visibility → real-time alerting with <30s detection latency

## Tech Stack

`Python` · `Prometheus` · `Grafana` · `Docker Compose` · `tcpdump` · `ffmpeg` · `Bash` · `UDP Multicast` · `RTP` · `IGMP`
