#!/usr/bin/env bash
# IGMP Snooping Test — run BEFORE turning on any TVs
# Determines if multicast is flooding the network or properly controlled
# Usage: sudo ./05_igmp_test.sh [interface] [duration_sec]

set -euo pipefail

IFACE="${1:-$(ip route | awk '/default/{print $5; exit}')}"
DURATION="${2:-30}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$REPORT_DIR/igmp_test_${TIMESTAMP}.md"

mkdir -p "$REPORT_DIR" "$LOG_DIR"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "${GRN}✓${NC} $*"; }
warn()  { echo -e "${YLW}⚠  FINDING:${NC} $*"; }
crit()  { echo -e "${RED}✗  CRITICAL:${NC} $*"; }
hdr()   { echo -e "\n${BLD}━━━ $* ━━━${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }
command -v tcpdump &>/dev/null || { echo "ERROR: tcpdump not installed"; exit 1; }

hdr "IGMP Snooping Test — $(date)"
echo -e "Interface : ${BLD}$IFACE${NC}"
echo -e "Duration  : ${BLD}${DURATION}s${NC}"
echo ""
echo -e "${YLW}IMPORTANT: Ensure ALL TVs are OFF before running this test.${NC}"
echo -e "${YLW}This test is only valid with zero active multicast receivers.${NC}"
echo ""
read -rp "Confirm all TVs are OFF and press Enter to start..."

hdr "Step 1: Check for multicast traffic with 0 receivers (${DURATION}s)"
echo "Listening for any 239.10.10.0/24 traffic..."
echo ""

TMPFILE=$(mktemp)
timeout "$DURATION" tcpdump -i "$IFACE" -n -q \
    'dst net 239.10.10.0/24' 2>/dev/null > "$TMPFILE" || true

PKT_COUNT=$(wc -l < "$TMPFILE")
UNIQUE_GROUPS=$(awk '{print $5}' "$TMPFILE" 2>/dev/null | \
    grep -oE '239\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | wc -l)
SAMPLE=$(head -5 "$TMPFILE")

echo ""
if [[ $PKT_COUNT -gt 0 ]]; then
    crit "Detected $PKT_COUNT multicast packets with NO TVs active!"
    crit "Multicast is flooding this network segment."
    echo ""
    echo "  Sample packets:"
    head -5 "$TMPFILE" | sed 's/^/    /'
    echo ""
    IGMP_STATUS="FLOODING"
    IGMP_SEVERITY="CRITICAL"
    IGMP_DETAIL="$PKT_COUNT packets across $UNIQUE_GROUPS groups in ${DURATION}s with zero receivers"
else
    ok "No multicast traffic detected with 0 receivers."
    ok "IGMP snooping appears to be working correctly."
    IGMP_STATUS="CONTROLLED"
    IGMP_SEVERITY="NONE"
    IGMP_DETAIL="Zero multicast packets observed in ${DURATION}s with no active receivers"
fi

hdr "Step 2: Check IGMP membership on this host"
echo "Current IGMP group memberships (from /proc/net/igmp):"
MEMBERSHIPS=$(awk 'NR>1 && $4~/^[0-9A-F]+$/{
    hex=$4
    printf "%d.%d.%d.%d\n",
        strtonum("0x" substr(hex,7,2)),
        strtonum("0x" substr(hex,5,2)),
        strtonum("0x" substr(hex,3,2)),
        strtonum("0x" substr(hex,1,2))
}' /proc/net/igmp 2>/dev/null | sort -u)

if echo "$MEMBERSHIPS" | grep -q "239\."; then
    ok "This host has joined multicast groups (exporter is running):"
    echo "$MEMBERSHIPS" | grep "239\." | sed 's/^/    /'
else
    warn "This host has no active 239.x.x.x memberships — exporter may not be running"
fi

hdr "Step 3: Network context"
MY_IP=$(ip addr show "$IFACE" | awk '/inet /{print $2; exit}')
MY_GW=$(ip route | awk '/default/{print $3; exit}')
echo "Monitor IP : $MY_IP"
echo "Gateway    : $MY_GW"

# ARP sweep — count active devices
ARP_COUNT=$(arp -n 2>/dev/null | grep -c "ether" || echo 0)
echo "ARP entries: $ARP_COUNT devices visible on this segment"

hdr "Generating report"

FLOOD_RATE="0"
[[ $PKT_COUNT -gt 0 ]] && FLOOD_RATE=$(echo "scale=1; $PKT_COUNT / $DURATION" | bc)

cat > "$REPORT" <<MARKDOWN
# IGMP Snooping Test Report

**Date:** $(date)
**Interface:** $IFACE
**Duration:** ${DURATION}s
**TVs active during test:** 0 (confirmed)

---

## Result: $IGMP_STATUS

| Parameter | Value |
|-----------|-------|
| Multicast packets observed | $PKT_COUNT |
| Unique groups flooding | $UNIQUE_GROUPS |
| Flood rate | ${FLOOD_RATE} pkt/s |
| IGMP snooping status | **$IGMP_STATUS** |
| Severity | $IGMP_SEVERITY |

**Finding:** $IGMP_DETAIL

---

## Interpretation

MARKDOWN

if [[ "$IGMP_STATUS" == "FLOODING" ]]; then
cat >> "$REPORT" <<MARKDOWN
### IGMP Snooping is OFF or misconfigured

With no TVs active, the switch is forwarding all IPTV multicast streams
to every port on the VLAN. This means:

- **200 TVs × N streams = full L2 multicast flood at all times**
- Every device on this VLAN receives all stream traffic regardless of whether
  it is watching anything
- Significant unnecessary bandwidth consumption on every access port
- Increased CPU load on switches (software multicast forwarding)

### Recommended Actions

1. Enable IGMP snooping on all access switches serving IPTV VLANs
2. Configure an IGMP Querier on the L3 switch or router
3. Enable PIM Sparse Mode if multicast routing is used between VLANs
4. Verify IGMP Snooping Querier interval is ≤ 125 seconds

### Business Impact

> "Without IGMP snooping, the hotel's IPTV system floods multicast to all
> 200 TV ports simultaneously, consuming maximum available bandwidth on every
> link regardless of viewership. Enabling IGMP snooping would reduce multicast
> traffic to only ports with active viewers, potentially reducing switch
> backplane load by 80–95% during low-viewership periods."
MARKDOWN
else
cat >> "$REPORT" <<MARKDOWN
### IGMP Snooping is functioning correctly

Multicast traffic is only forwarded to ports where a device has sent an
IGMP membership report. The network is correctly controlled.

### Observations

- No unnecessary multicast flooding detected
- Switch is correctly filtering multicast at L2
- IPTV traffic will only reach TVs that are actively tuned to a channel
MARKDOWN
fi

cat >> "$REPORT" <<MARKDOWN

---

## Network Context

| Parameter | Value |
|-----------|-------|
| Monitor host IP | $MY_IP |
| Default gateway | $MY_GW |
| Visible ARP entries | $ARP_COUNT devices |

---

*Generated by hotel-iptv/scripts/05_igmp_test.sh — $(date)*
MARKDOWN

rm -f "$TMPFILE"
ok "Report saved: $REPORT"
echo ""
cat "$REPORT"
