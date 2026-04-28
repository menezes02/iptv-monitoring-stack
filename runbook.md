# IPTV Monitoring Runbook — Hotel 200-TV Deployment

## Quick Reference

| Action | Command |
|--------|---------|
| Start monitoring stack | `cd hotel-iptv && docker compose up -d` |
| Phase 1 baseline scan | `sudo ./scripts/01_baseline_scan.sh eth0 60` |
| Decode stream test | `sudo ./scripts/02_stream_decoder_test.sh 239.10.10.1 1234 120` |
| Generate CV report | `./scripts/03_generate_cv_report.sh` |
| Grafana | http://localhost:3000 (admin / iptv2024) |
| Prometheus | http://localhost:9090 |
| IPTV exporter metrics | http://localhost:9200/metrics |

---

## Architecture

```
[Headend / IPTV Server]
        │
        │  UDP Multicast 239.10.10.1–20:1234–1250
        ▼
[Core Switch] ──────── [Monitor Host (this machine)]
        │                       │
   [Access Switches]       Docker stack:
        │                  Prometheus :9090
   [200 Google TVs]        Grafana    :3000
                           Node Exporter :9100
                           IPTV Exporter :9200
```

**Key constraint:** No switch/router admin access. All monitoring is passive
(receive-only) from this host. No traffic is injected into the network.

---

## Multicast Address Space

| Parameter | Value |
|-----------|-------|
| Multicast range | 239.10.10.1 – 239.10.10.20 |
| Port range | 1234 – 1250 |
| Protocol | UDP (MPEG-TS over RTP likely) |
| Total stream targets | 17 ports × 20 groups = 340 combinations |

---

## Phase 1: Baseline Scan

```bash
# Ensure tcpdump is installed
sudo apt-get install -y tcpdump ffmpeg

# Run full baseline scan (60-second measurement window)
cd hotel-iptv
sudo ./scripts/01_baseline_scan.sh eth0 60

# Output files:
#   reports/baseline_report.md   — structured findings
#   logs/scan_TIMESTAMP.log      — raw packet counts
```

**If no streams are found:** TVs are off or IGMP is blocking joins.
Document this as "infrastructure readiness assessment" — the monitoring
stack deployment still demonstrates the same skills.

---

## Phase 2: Deploy Monitoring Stack

```bash
# Start all services
cd hotel-iptv
docker compose up -d

# Verify all containers are up
docker compose ps

# Check exporter is receiving data (within ~30s of TVs being on)
curl -s http://localhost:9200/metrics | grep iptv_active

# Verify Prometheus is scraping
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health

# Open Grafana
xdg-open http://localhost:3000
# Login: admin / iptv2024
```

**Troubleshooting:**
- Exporter shows 0 active streams: check `docker logs iptv_exporter` for socket errors
- Grafana shows "No data": wait 30s for first Prometheus scrape, check datasource URL
- Port conflict: `ss -tlnp | grep -E '3000|9090|9200'`

---

## Phase 3: Stream Quality Test

```bash
# Test decode on specific stream (replace with discovered group:port)
sudo ./scripts/02_stream_decoder_test.sh 239.10.10.1 1234 120

# Quick ffprobe check
ffprobe -v quiet -print_format json -show_streams \
    "udp://@239.10.10.1:1234?fifo_size=1000000" 2>&1 | head -60

# Watch live packet counts (ctrl-C to stop)
sudo tcpdump -i eth0 -n 'udp and dst net 239.0.0.0/8' -c 1000 | \
    awk '{print $5}' | sort | uniq -c | sort -rn
```

---

## Metrics Glossary

| Metric | Meaning | Alert Threshold |
|--------|---------|----------------|
| `iptv_active_streams_total` | Count of groups sending packets | <1 = critical |
| `iptv_stream_bitrate_kbps` | kbps per stream (10s window) | <500 = warn |
| `iptv_stream_packets_per_sec` | UDP packets/sec per stream | — |
| `iptv_stream_loss_percent` | RTP sequence gap loss estimate | >5% = warn |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| IGMP snooping disabled | Medium | High — multicast floods all ports | Confirm with switch vendor |
| No VLAN isolation | Medium | Medium — IPTV shares bandwidth with management | Recommend dedicated VLAN |
| Single headend | Unknown | High — full outage if source fails | Recommend redundant source |
| No stream authentication | Low | Medium — rogue injection possible | Network access controls |

---

## Stopping / Cleanup

```bash
# Stop stack (preserves data)
docker compose stop

# Full teardown (destroys volumes/data)
docker compose down -v
```

---

*Runbook version 1.0 — generated during on-site engagement*
