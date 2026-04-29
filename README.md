# Hotel IPTV Monitoring Stack

Real-time monitoring stack for UDP multicast IPTV infrastructure, built and deployed during a live hotel engagement. Discovers, identifies, and continuously measures every channel on the network — with zero access to switches, routers, or the headend encoder.

## What It Does

- Joins UDP multicast groups and measures **bitrate, packet loss, jitter, and burst events** per channel in real time
- Auto-discovers channel names from MPEG-TS SDT (Service Description Table) via ffprobe — no manual config needed
- Polls the **CMP201AD headend** via SNMP v2c for encoder uptime, interface throughput, and error rates
- Exposes all metrics to **Prometheus**, visualised in **Grafana** with a pre-built dashboard
- Fires alerts within 30–120 seconds of degradation — stream loss, high jitter, headend failure

## Real-World Results

Deployed at a 200-room hotel in Dublin:

| Metric | Result |
|--------|--------|
| Channels discovered | **42** (40 named via SDT auto-discovery) |
| Aggregate bitrate monitored | **161.1 Mbps** |
| Packet loss across all streams | **0.00%** |
| Avg jitter — HD video channels | **< 2 ms** |
| Multicast range | `227.10.20.2 – 227.10.20.51 : 1234` |
| Time to full visibility | **< 60 seconds** from first connection |

Channel lineup included: RTÉ One/2/News, TG4, BBC One NI HD, BBC Two HD, ITV1/2 HD, Channel 4 HD, UTV HD, 5 HD, Sky News, CNN HD, Bloomberg HD, FRANCE 24 HD, Virgin Media 1–4, CBeebies HD, CBBC HD, and more.

## Architecture

```
  CMP201AD Headend (Wellav)
        │  UDP multicast 227.10.20.x:1234
        ▼
  Hotel LAN switch (IGMP snooping)
        │
        └── Monitor Laptop
            ┌──────────────────────────────────────────┐
            │  iptv_exporter    :9200  ← multicast RX  │
            │  headend_exporter :9300  ← SNMP polls    │
            │  node_exporter    :9100  ← host metrics  │
            │                                          │
            │  Prometheus :9090  ← scrapes all (15s)   │
            │  Grafana    :3000  ← dashboard + alerts  │
            └──────────────────────────────────────────┘
```

All services run as Docker containers. The IPTV exporter uses host networking to join multicast groups directly on the host NIC.

## Metrics

### Stream Metrics (per channel, labelled by `channel` and `multicast_group`)

| Metric | Description |
|--------|-------------|
| `iptv_stream_bitrate_kbps` | Bitrate over 10s measurement window |
| `iptv_stream_loss_percent` | Packet loss % (sequence-number based) |
| `iptv_stream_jitter_ms` | Mean interarrival jitter |
| `iptv_stream_burst_events_total` | Consecutive drop events (≥3 packets) |
| `iptv_stream_uptime_seconds` | Time since first packet on stream |
| `iptv_active_streams_total` | Count of currently active streams |

### Headend Metrics (CMP201AD via SNMP v2c)

| Metric | Description |
|--------|-------------|
| `headend_up` | 1 if SNMP reachable, 0 if not |
| `headend_uptime_seconds` | Encoder uptime |
| `headend_interface_up` | Per-interface operational status |
| `headend_interface_rx_bytes_total` | RX bytes per interface |
| `headend_interface_tx_bytes_total` | TX bytes per interface |
| `headend_interface_rx_errors_total` | RX errors per interface |
| `headend_http_reachable` | 1 if web GUI responds on port 80 |

## Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| `StreamHighPacketLoss` | loss > 5% for 1 min | warning |
| `StreamCompleteLoss` | loss == 100% for 30s | critical |
| `ActiveStreamCountDrop` | 0 active streams for 2 min | critical |
| `StreamHighJitter` | jitter > 20ms for 1 min | warning |
| `StreamBurstLoss` | burst events > 2 | warning |
| `HeadendUnreachable` | SNMP down for 1 min | critical |
| `HeadendInterfaceDown` | interface down for 30s | warning |
| `HeadendHighRxErrors` | RX errors > 10/s for 2 min | warning |
| `MonitorHighCPU` | CPU > 85% for 5 min | warning |

## Quick Start

```bash
# Clone and enter
git clone https://github.com/menezes02/iptv-monitoring-stack.git
cd iptv-monitoring-stack

# Start the full stack
docker compose up -d

# Discover headend IP on-site
./scripts/09_headend_discover.sh

# Start monitoring with real headend IP
HEADEND_IP=192.168.x.x docker compose up -d headend_exporter

# Run morning readiness check
./scripts/00_morning_check.sh

# Open dashboard
xdg-open http://localhost:3000   # login: admin / iptv2024
```

> **On-site:** set your ethernet interface up first:
> `sudo ip link set enp2s0 up`

## Scripts

| Script | Purpose |
|--------|---------|
| `00_morning_check.sh` | Pre-site readiness check — verifies all containers, endpoints, and targets |
| `01_baseline_scan.sh` | Passive multicast scanner — finds all live streams on the network |
| `02_stream_decoder_test.sh` | ffmpeg decode test — confirms streams are decodable end-to-end |
| `03_generate_cv_report.sh` | Generates a text-based site report from live metrics |
| `04_ffprobe_inventory.sh` | Probes each stream for codec, resolution, and bitrate |
| `05_igmp_test.sh` | IGMP snooping diagnostic — validates switch forwarding behaviour |
| `06_load_test.sh` | Load test — simulates multiple IGMP joins to stress the switch |
| `07_terminal_dashboard.sh` | Live terminal dashboard — stream health at a glance without Grafana |
| `08_end_of_day.sh` | End-of-day wrap — exports metrics snapshot and tidies logs |
| `09_headend_discover.sh` | Auto-discovers CMP201AD headend IP on the local network |
| `iptv_exporter.py` | Custom Prometheus exporter — core stream measurement engine |
| `headend_snmp_exporter.py` | SNMP exporter for CMP201AD headend metrics |
| `mock_streams.py` | Simulates multicast streams for local testing without a real headend |

## Channel Name Auto-Discovery

The exporter automatically discovers channel names from the MPEG-TS Service Description Table (SDT) using ffprobe. Names are cached to `logs/channel_names.json` so they survive container restarts. No manual channel map required.

```
iptv_stream_bitrate_kbps{channel="BBC Two HD", multicast_group="227.10.20.10", port="1234"} 13498
iptv_stream_bitrate_kbps{channel="RTÉ One",    multicast_group="227.10.20.2",  port="1234"} 3796
```

## Configuration

| Environment variable | Default | Description |
|----------------------|---------|-------------|
| `HEADEND_IP` | `192.168.1.10` | CMP201AD IP address |
| `SNMP_COMMUNITY` | `public` | SNMP v2c community string |
| `POLL_INTERVAL` | `30` | Headend poll interval (seconds) |
| `EXPORTER_PORT` | `9300` | Headend exporter HTTP port |

Set via `.env` file or `docker compose` environment:

```bash
HEADEND_IP=192.168.20.7 SNMP_COMMUNITY=public docker compose up -d
```

## Engagement Context

- **Site:** 200-room hotel, Dublin
- **Headend:** Wellav CMP201AD (up to 120 MPEG-TS output channels)
- **Constraint:** No access to switch, router, or headend admin — passive monitoring only
- **Approach:** IGMP join on each multicast group, measure packet flow per channel
- **Detection latency:** < 30s for stream loss, < 60s for headend failure

## Tech Stack

`Python 3` · `Prometheus` · `Grafana` · `Docker Compose` · `FFmpeg / ffprobe` · `pysnmp` · `Bash` · `UDP Multicast` · `MPEG-TS` · `IGMP` · `SNMP v2c`
