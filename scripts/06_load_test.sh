#!/usr/bin/env bash
# Phase 3: Incremental load test — log metrics at each TV batch
# Usage: sudo ./06_load_test.sh [interface] [batch_size] [measure_sec]
# Example: sudo ./06_load_test.sh enp2s0 20 60

set -euo pipefail

IFACE="${1:-$(ip route | awk '/default/{print $5; exit}')}"
BATCH="${2:-20}"
MEASURE="${3:-60}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV="$LOG_DIR/load_test_${TIMESTAMP}.csv"
REPORT="$REPORT_DIR/load_test_${TIMESTAMP}.md"
SNAPSHOT="$LOG_DIR/metrics_snapshot.json"

mkdir -p "$REPORT_DIR" "$LOG_DIR"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
warn() { echo -e "${YLW}!${NC} $*"; }
hdr()  { echo -e "\n${BLD}=== $* ===${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

echo "tv_count,timestamp,active_streams,avg_loss_pct,max_loss_pct,avg_jitter_ms,max_jitter_ms,total_bitrate_kbps,burst_events_total" > "$CSV"

collect_metrics() {
    local tv_count="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    STATS=$(python3 -c "
import json, sys
try:
    d = json.load(open('$SNAPSHOT'))
    streams = d.get('streams', [])
    if not streams:
        print('0,0,0,0,0,0,0')
        sys.exit(0)
    losses  = [s['loss_pct'] for s in streams]
    jitters = [s['jitter_ms'] for s in streams]
    bursts  = sum(s['burst_events'] for s in streams)
    kbps    = sum(s['bitrate_kbps'] for s in streams)
    print(f\"{len(streams)},{sum(losses)/len(losses):.2f},{max(losses):.2f},{sum(jitters)/len(jitters):.2f},{max(jitters):.2f},{kbps:.0f},{bursts}\")
except Exception as e:
    print('0,0,0,0,0,0,0')
" 2>/dev/null)

    echo "${tv_count},${ts},${STATS}" >> "$CSV"
    echo "$STATS"
}

hdr "IPTV Load Test — $(date)"
echo -e "Interface  : $IFACE"
echo -e "Batch size : $BATCH TVs"
echo -e "Measure    : ${MEASURE}s per step"
echo -e "CSV output : $CSV"
echo ""

TV_COUNT=0
declare -A RESULTS

while true; do
    hdr "Step: $TV_COUNT TVs active"

    echo -e "${YLW}Waiting ${MEASURE}s to collect metrics...${NC}"
    sleep "$MEASURE"

    STATS=$(collect_metrics "$TV_COUNT")
    IFS=',' read -r ACTIVE AVG_LOSS MAX_LOSS AVG_JITTER MAX_JITTER KBPS BURSTS <<< "$STATS"
    MBPS=$(awk "BEGIN{printf \"%.1f\", $KBPS/1000}")

    echo ""
    echo -e "  Active streams  : ${BLD}$ACTIVE${NC}"
    echo -e "  Avg loss        : ${BLD}${AVG_LOSS}%${NC}"
    echo -e "  Max loss        : ${BLD}${MAX_LOSS}%${NC}"
    echo -e "  Avg jitter      : ${BLD}${AVG_JITTER}ms${NC}"
    echo -e "  Max jitter      : ${BLD}${MAX_JITTER}ms${NC}"
    echo -e "  Total bitrate   : ${BLD}${MBPS} Mbps${NC}"
    echo -e "  Burst events    : ${BLD}$BURSTS${NC}"

    # Flag degradation
    if (( $(echo "$MAX_LOSS > 5" | bc -l) )); then
        echo -e "  ${RED}⚠ WARNING: Loss >5% detected — network degrading at $TV_COUNT TVs${NC}"
    fi
    if (( $(echo "$AVG_JITTER > 20" | bc -l) )); then
        echo -e "  ${YLW}⚠ WARNING: High jitter at $TV_COUNT TVs — buffering likely on TVs${NC}"
    fi

    RESULTS[$TV_COUNT]="$ACTIVE|$AVG_LOSS|$MAX_LOSS|$AVG_JITTER|$MAX_JITTER|$MBPS|$BURSTS"

    echo ""
    echo -e "${BLD}Options:${NC}"
    echo -e "  [n] Add next batch of $BATCH TVs"
    echo -e "  [c] Custom TV count (enter number)"
    echo -e "  [d] Done — generate report"
    echo -n "Choice: "
    read -r CHOICE

    case "$CHOICE" in
        n|N|"")
            TV_COUNT=$((TV_COUNT + BATCH))
            echo ""
            echo -e "${YLW}>>> Turn on $BATCH more TVs now (total: $TV_COUNT) then press Enter when done${NC}"
            read -r
            ;;
        c|C)
            echo -n "Enter total TV count now active: "
            read -r TV_COUNT
            echo -e "${YLW}>>> Confirm $TV_COUNT TVs are on, press Enter to measure${NC}"
            read -r
            ;;
        d|D)
            break
            ;;
    esac
done

hdr "Generating load test report"

cat > "$REPORT" <<MARKDOWN
# IPTV Load Test Report

**Date:** $(date)
**Interface:** $IFACE
**Batch size:** $BATCH TVs per step
**Measurement window:** ${MEASURE}s per step

---

## Results by TV Count

| TVs Active | Streams | Avg Loss% | Max Loss% | Avg Jitter | Max Jitter | Total Mbps | Burst Events |
|-----------|---------|-----------|-----------|------------|------------|------------|--------------|
MARKDOWN

for TV in $(echo "${!RESULTS[@]}" | tr ' ' '\n' | sort -n); do
    IFS='|' read -r ACTIVE AVG_LOSS MAX_LOSS AVG_JITTER MAX_JITTER MBPS BURSTS <<< "${RESULTS[$TV]}"
    WARN=""
    (( $(echo "$MAX_LOSS > 5" | bc -l) )) && WARN=" ⚠"
    echo "| $TV | $ACTIVE | ${AVG_LOSS}% | ${MAX_LOSS}%${WARN} | ${AVG_JITTER}ms | ${MAX_JITTER}ms | $MBPS | $BURSTS |" >> "$REPORT"
done

cat >> "$REPORT" <<MARKDOWN

---

## Key Findings

> Fill in after reviewing the data above:
> - Network remained stable up to ___ concurrent TVs
> - Degradation first observed at ___ TVs (loss: ___%, jitter: ___ms)
> - Maximum tested load: ___ TVs, ___ Mbps aggregate
> - Burst loss events suggest: ___

---

## CV Bullet (template)

> "Conducted incremental load testing on live hotel IPTV infrastructure,
> activating up to ___ concurrent streams in batches of $BATCH.
> Network maintained <1% packet loss up to ___ TVs;
> degradation threshold identified at ___ TVs with ___% peak loss."

---

*Raw data: $CSV*
*Generated: $(date)*
MARKDOWN

ok "Report: $REPORT"
ok "CSV data: $CSV"
echo ""
cat "$REPORT"
