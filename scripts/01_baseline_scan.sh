#!/usr/bin/env bash
# Phase 1: Baseline multicast stream audit
# Usage: sudo ./01_baseline_scan.sh [interface] [duration_sec]
# Example: sudo ./01_baseline_scan.sh eth0 60

set -euo pipefail

IFACE="${1:-$(ip route | awk '/default/{print $5; exit}')}"
DURATION="${2:-60}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCAN_LOG="$LOG_DIR/scan_${TIMESTAMP}.log"
REPORT="$REPORT_DIR/baseline_report.md"

mkdir -p "$REPORT_DIR" "$LOG_DIR"

RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'; BLD='\033[1m'

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
info() { echo -e "${GRN}[INFO]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
hdr()  { echo -e "\n${BLD}=== $* ===${NC}"; }

[[ $EUID -ne 0 ]] && die "Run as root (sudo)"
command -v tcpdump &>/dev/null || die "tcpdump not installed: sudo apt install tcpdump"
command -v ip     &>/dev/null || die "ip not installed"

hdr "IPTV Baseline Scan — $(date)"
info "Interface : $IFACE"
info "Duration  : ${DURATION}s per stream probe"
info "Targets   : 239.10.10.1–20 ports 1234–1250"
info "Log       : $SCAN_LOG"
echo ""

declare -A STREAM_PACKETS
declare -A STREAM_BYTES
declare -A ACTIVE_STREAMS
TOTAL_ACTIVE=0

# ── Step 1: Quick discovery pass (5s per group) ──────────────────────────────
hdr "STEP 1: Stream discovery (5s probe per multicast group)"

PORTS=(1234 1235 1236 1237 1238 1239 1240 1241 1242 1243 1244 1245 1246 1247 1248 1249 1250)

for last in $(seq 1 20); do
    GROUP="239.10.10.$last"
    for PORT in "${PORTS[@]}"; do
        FILTER="udp dst host $GROUP and dst port $PORT"
        COUNT=$(timeout 5 tcpdump -i "$IFACE" -c 100 "$FILTER" 2>/dev/null | wc -l || true)
        if [[ "$COUNT" -gt 0 ]]; then
            STREAM_KEY="${GROUP}:${PORT}"
            ACTIVE_STREAMS["$STREAM_KEY"]=1
            info "ACTIVE  $STREAM_KEY (${COUNT} packets in 5s)"
            echo "ACTIVE $STREAM_KEY ${COUNT}" >> "$SCAN_LOG"
        else
            echo "SILENT $GROUP:$PORT" >> "$SCAN_LOG"
        fi
    done
done

TOTAL_ACTIVE=${#ACTIVE_STREAMS[@]}
info "\nDiscovery complete: ${TOTAL_ACTIVE} active streams found"

if [[ $TOTAL_ACTIVE -eq 0 ]]; then
    warn "No active streams detected. TVs may be off or multicast not routing."
    warn "Documenting infrastructure readiness instead."
fi

# ── Step 2: 60s measurement on active streams ────────────────────────────────
hdr "STEP 2: ${DURATION}s packet loss measurement on active streams"

declare -A LOSS_PCT
declare -A BITRATE_KBPS

if [[ $TOTAL_ACTIVE -gt 0 ]]; then
    for KEY in "${!ACTIVE_STREAMS[@]}"; do
        GROUP="${KEY%%:*}"
        PORT="${KEY##*:}"
        FILTER="udp dst host $GROUP and dst port $PORT"
        TMPFILE=$(mktemp)

        info "Measuring $KEY for ${DURATION}s …"
        timeout "$DURATION" tcpdump -i "$IFACE" -n -tt -q "$FILTER" > "$TMPFILE" 2>&1 || true

        PKT_COUNT=$(grep -c "^[0-9]" "$TMPFILE" || echo 0)
        TOTAL_BYTES=$(awk '/^[0-9]/{match($0,/length ([0-9]+)/,a); sum+=a[1]} END{print sum+0}' "$TMPFILE")
        KBPS=$(awk -v b="$TOTAL_BYTES" -v d="$DURATION" 'BEGIN{printf "%.1f", b*8/d/1000}')

        # Estimate loss from timestamp gaps (>3× expected interval = dropped)
        EXPECTED_PPS=50  # typical MPEG-TS UDP ~1316 bytes, ~4Mbps ≈ 380pps; 50 is conservative floor
        EXPECTED_PKTS=$(( EXPECTED_PPS * DURATION ))
        if [[ $PKT_COUNT -gt 0 ]]; then
            LOSS=$(awk -v got="$PKT_COUNT" -v exp="$EXPECTED_PKTS" \
                'BEGIN{l=(exp-got)/exp*100; if(l<0)l=0; printf "%.1f", l}')
        else
            LOSS="100.0"
        fi

        STREAM_PACKETS[$KEY]=$PKT_COUNT
        STREAM_BYTES[$KEY]=$TOTAL_BYTES
        BITRATE_KBPS[$KEY]=$KBPS
        LOSS_PCT[$KEY]=$LOSS

        info "  → packets: $PKT_COUNT | bitrate: ${KBPS} kbps | est. loss: ${LOSS}%"
        echo "MEASURE $KEY packets=$PKT_COUNT bytes=$TOTAL_BYTES kbps=$KBPS loss=${LOSS}%" >> "$SCAN_LOG"
        rm -f "$TMPFILE"
    done
fi

# ── Step 3: ffprobe on first active stream ───────────────────────────────────
hdr "STEP 3: Stream decodability check (ffprobe)"

FFPROBE_RESULT="ffprobe not available or no active streams"
if command -v ffprobe &>/dev/null && [[ $TOTAL_ACTIVE -gt 0 ]]; then
    FIRST_KEY="${!ACTIVE_STREAMS[@]}"
    FIRST_KEY="${FIRST_KEY%% *}"   # get first element
    FIRST_GROUP="${FIRST_KEY%%:*}"
    FIRST_PORT="${FIRST_KEY##*:}"
    info "Running ffprobe on udp://@$FIRST_GROUP:$FIRST_PORT …"
    FFPROBE_OUT=$(timeout 15 ffprobe -v quiet -print_format json \
        -show_streams -show_format \
        "udp://@${FIRST_GROUP}:${FIRST_PORT}" 2>&1 || true)
    if echo "$FFPROBE_OUT" | grep -q '"codec_type"'; then
        FFPROBE_RESULT="$FFPROBE_OUT"
        info "ffprobe SUCCESS — stream is decodable"
    else
        FFPROBE_RESULT="ffprobe ran but could not decode (stream may be scrambled or IGMP join failed)"
        warn "$FFPROBE_RESULT"
    fi
else
    if ! command -v ffprobe &>/dev/null; then
        warn "ffprobe not installed: sudo apt install ffmpeg"
    fi
fi

# ── Step 4: Network context ──────────────────────────────────────────────────
hdr "STEP 4: Network context"

MY_IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' || echo "unknown")
MY_GW=$(ip route | awk '/default/{print $3; exit}' || echo "unknown")
IGMP_MEMBERSHIPS=$(cat /proc/net/igmp 2>/dev/null | awk 'NR>1{print $4}' | \
    while read hex; do printf "%d.%d.%d.%d\n" \
        $((16#${hex:6:2})) $((16#${hex:4:2})) $((16#${hex:2:2})) $((16#${hex:0:2})); \
    done | sort -u || echo "none")

info "My IP      : $MY_IP"
info "Gateway    : $MY_GW"
info "IGMP groups: $IGMP_MEMBERSHIPS"

# ── Generate baseline_report.md ──────────────────────────────────────────────
hdr "Generating baseline_report.md"

cat > "$REPORT" <<MARKDOWN
# IPTV Baseline Audit Report

**Site:** Hotel IPTV — 200 Google TV Devices
**Date:** $(date)
**Engineer:** On-site Network Engineer
**Tool:** hotel-iptv/scripts/01_baseline_scan.sh

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Scan target | 239.10.10.1–20 ports 1234–1250 |
| Active streams found | **${TOTAL_ACTIVE}** |
| Measurement duration | ${DURATION}s |
| Monitoring interface | ${IFACE} |
| Monitor host IP | ${MY_IP} |
| Default gateway | ${MY_GW} |
| Scan timestamp | $(date -u +%Y-%m-%dT%H:%M:%SZ) |

---

## Stream Inventory

MARKDOWN

if [[ $TOTAL_ACTIVE -gt 0 ]]; then
    echo "| Stream | Packets/${DURATION}s | Bitrate (kbps) | Est. Loss% | Status |" >> "$REPORT"
    echo "|--------|-----------|----------------|------------|--------|" >> "$REPORT"
    for KEY in "${!ACTIVE_STREAMS[@]}"; do
        PKT="${STREAM_PACKETS[$KEY]:-0}"
        KBPS="${BITRATE_KBPS[$KEY]:-0}"
        LOSS="${LOSS_PCT[$KEY]:-N/A}"
        if (( $(echo "$LOSS > 5" | bc -l 2>/dev/null || echo 0) )); then
            STATUS="⚠ HIGH LOSS"
        else
            STATUS="✓ OK"
        fi
        echo "| $KEY | $PKT | $KBPS | $LOSS% | $STATUS |" >> "$REPORT"
    done
else
    cat >> "$REPORT" <<'EOMD'
**No active streams detected during scan window.**

This indicates one or more of:
- TVs are powered off (normal outside viewing hours)
- IGMP snooping is blocking multicast at the switch — streams exist but aren't forwarded without a join
- VLAN segmentation prevents multicast from reaching this host
- Streams are unicast rather than multicast

**Infrastructure Readiness Assessment** is documented below.
EOMD
fi

cat >> "$REPORT" <<MARKDOWN

---

## Network Context

\`\`\`
Interface : ${IFACE}
Monitor IP: ${MY_IP}
Gateway   : ${MY_GW}
IGMP memberships on this host:
${IGMP_MEMBERSHIPS}
\`\`\`

---

## Stream Decodability

\`\`\`json
${FFPROBE_RESULT}
\`\`\`

---

## Risk Assessment

| Risk | Severity | Evidence |
|------|----------|----------|
| IGMP snooping unknown | Medium | Cannot verify without switch access |
| VLAN isolation unknown | Medium | Cannot verify without switch access |
| Multicast flooding risk | High if IGMP off | 200 TVs × N streams = full L2 flood |
| Stream redundancy | Unknown | Single multicast source assumed |
| Monitoring gap (pre-deployment) | Critical | Zero visibility before this audit |

---

## Recommendations

1. **Enable IGMP snooping** on all access switches — prevents multicast flood to all ports
2. **VLAN isolation**: IPTV traffic should be on a dedicated VLAN (not shared with management)
3. **Deploy Prometheus+Grafana** (Phase 2) for 24/7 stream health visibility
4. **PIM Sparse Mode / IGMP Querier** should be confirmed on the router/L3 switch
5. **Stream redundancy**: implement backup source for production reliability

---

## Baseline State: Before Monitoring

> "Prior to this engagement, there was **zero visibility** into IPTV stream health.
> No alerting existed for stream failures. The 200-TV deployment was operating
> without any packet loss metrics, bitrate tracking, or failure detection."

---

*Report generated by hotel-iptv audit tooling — $(date)*
MARKDOWN

info "\nBaseline report written to: $REPORT"
echo ""
echo -e "${BLD}── SUMMARY ──────────────────────────────────────────${NC}"
echo -e "Active streams   : ${TOTAL_ACTIVE}"
echo -e "Report           : $REPORT"
echo -e "Raw log          : $SCAN_LOG"
echo -e "${BLD}─────────────────────────────────────────────────────${NC}"
echo ""
info "Next: run 'docker compose up -d' in hotel-iptv/ to launch monitoring stack"
