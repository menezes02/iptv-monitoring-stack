#!/usr/bin/env bash
# Live terminal dashboard — stream health at a glance without opening a browser
# Usage: ./07_terminal_dashboard.sh [refresh_interval_sec]

INTERVAL="${1:-10}"
SNAPSHOT="$(cd "$(dirname "$0")/.." && pwd)/logs/metrics_snapshot.json"

command -v python3 &>/dev/null || { echo "python3 required"; exit 1; }

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
CLS='\033[H\033[2J'

status_color() {
    local loss="$1" jitter="$2"
    if (( $(echo "$loss > 5" | bc -l 2>/dev/null || echo 0) )); then echo -e "${RED}"
    elif (( $(echo "$loss > 2" | bc -l 2>/dev/null || echo 0) )); then echo -e "${YLW}"
    elif (( $(echo "$jitter > 20" | bc -l 2>/dev/null || echo 0) )); then echo -e "${YLW}"
    else echo -e "${GRN}"; fi
}

while true; do
    echo -ne "$CLS"

    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLD}━━━ IPTV Stream Monitor ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}  $NOW"
    echo ""

    if [[ ! -f "$SNAPSHOT" ]]; then
        echo -e "${YLW}Waiting for first measurement window (~10s)...${NC}"
        sleep "$INTERVAL"
        continue
    fi

    python3 - "$SNAPSHOT" <<'PYEOF'
import json, sys, math

SNAPSHOT = sys.argv[1]
try:
    d = json.load(open(SNAPSHOT))
except:
    print("Cannot read snapshot")
    sys.exit(0)

streams = d.get("streams", [])
active  = d.get("active_count", 0)
ts      = d.get("timestamp", "")

RED  = '\033[0;31m'; GRN  = '\033[0;32m'; YLW = '\033[1;33m'
BLD  = '\033[1m';    DIM  = '\033[2m';    NC  = '\033[0m'

def color(loss, jitter):
    if loss > 5:   return RED
    if loss > 2:   return YLW
    if jitter > 20: return YLW
    return GRN

def bar(val, max_val=10000, width=12):
    filled = int(min(val / max_val, 1.0) * width)
    return '█' * filled + '░' * (width - filled)

total_kbps = sum(s['bitrate_kbps'] for s in streams)

print(f"  {BLD}Active Streams:{NC} {active}   "
      f"{BLD}Total Bitrate:{NC} {total_kbps/1000:.1f} Mbps   "
      f"{DIM}Updated: {ts}{NC}")
print()

if not streams:
    print(f"  {YLW}No active streams detected.{NC}")
    print(f"  {DIM}TVs may be off, or IGMP snooping is blocking multicast joins.{NC}")
else:
    HDR = f"  {'CHANNEL':<24} {'KBPS':>6}  {'LOSS%':>6}  {'JITTER':>7}  {'BURST':>5}  {'UPTIME':>8}  BITRATE"
    print(f"{BLD}{HDR}{NC}")
    print("  " + "─" * 85)

    for s in sorted(streams, key=lambda x: x['loss_pct'], reverse=True):
        ch      = s['channel'][:23]
        kbps    = s['bitrate_kbps']
        loss    = s['loss_pct']
        jitter  = s['jitter_ms']
        burst   = s['burst_events']
        uptime  = s['uptime_sec']
        c       = color(loss, jitter)

        mins = int(uptime // 60)
        secs = int(uptime % 60)
        up_str = f"{mins}m{secs:02d}s"

        loss_flag  = " ⚠" if loss > 5 else "  "
        jit_flag   = " ⚠" if jitter > 20 else "  "

        b = bar(kbps, max_val=8000)
        print(f"  {c}{ch:<24}{NC} "
              f"{kbps:>6.0f}  "
              f"{c}{loss:>5.1f}%{loss_flag}{NC}  "
              f"{c}{jitter:>5.1f}ms{jit_flag}{NC}  "
              f"{burst:>5}  "
              f"{up_str:>8}  "
              f"{DIM}{b}{NC}")

    print()
    degraded = [s for s in streams if s['loss_pct'] > 5]
    if degraded:
        print(f"  {RED}{BLD}⚠ DEGRADED:{NC}", ", ".join(s['channel'] for s in degraded))
    else:
        print(f"  {GRN}All streams healthy{NC}")

print()
PYEOF

    echo -e "${DIM}  Prometheus: http://localhost:9090  |  Grafana: http://localhost:3000  |  Channels: http://localhost:9200/channels${NC}"
    echo -e "${DIM}  Refresh: ${INTERVAL}s  |  Ctrl-C to exit${NC}"
    sleep "$INTERVAL"
done
