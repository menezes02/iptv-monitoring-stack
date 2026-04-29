#!/usr/bin/env bash
# Morning readiness check — run before leaving for the hotel
# Verifies the full stack is healthy and ready for on-site work

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0
ok()   { echo -e "${GRN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "${YLW}!${NC} $*"; }
hdr()  { echo -e "\n${BLD}── $* ──────────────────────────────────${NC}"; }

echo -e "${BLD}IPTV Stack — Morning Readiness Check${NC}"
echo -e "$(date)\n"

hdr "Tools"
for t in docker tcpdump ffmpeg ffprobe ffplay wireshark python3; do
    command -v "$t" &>/dev/null && ok "$t" || fail "$t not installed"
done

hdr "Docker containers"
for svc in iptv_prometheus iptv_grafana iptv_node_exporter iptv_exporter iptv_headend_exporter; do
    STATUS=$(docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
    [[ "$STATUS" == "running" ]] && ok "$svc running" || fail "$svc is $STATUS"
done

hdr "Endpoints"
check_url() {
    local name="$1" url="$2" expect="$3"
    RESP=$(curl -s --max-time 3 "$url" 2>/dev/null || echo "")
    if echo "$RESP" | grep -q "$expect"; then
        ok "$name ($url)"
    else
        fail "$name unreachable ($url)"
        if [[ "$name" == *"Prometheus"* ]]; then
            warn "  Fix: cd ~/hotel-iptv && docker compose up -d"
        fi
    fi
}
check_url "Grafana"           "http://localhost:3000/api/health"  '"ok"'
check_url "Prometheus"        "http://localhost:9090/-/healthy"    "Prometheus"
check_url "IPTV Exporter"     "http://localhost:9200/health"      "ok"
check_url "Node Exporter"     "http://localhost:9100/metrics"     "node_"
check_url "Headend Exporter"  "http://localhost:9300/health"      "ok"

hdr "Prometheus scrape targets"
TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null)
for job in prometheus iptv_exporter node_exporter headend_exporter; do
    HEALTH=$(echo "$TARGETS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    if t['labels']['job']=='$job':
        print(t['health'])
        break
" 2>/dev/null || echo "unknown")
    [[ "$HEALTH" == "up" ]] && ok "$job scraping" || fail "$job scrape health: $HEALTH"
done

hdr "Network interfaces"
for iface in enp2s0 eth0 ens33 wlp3s0; do
    INFO=$(ip addr show "$iface" 2>/dev/null)
    if [[ -n "$INFO" ]]; then
        STATE=$(echo "$INFO" | awk '/UP|DOWN/{print $3; exit}' | tr -d '<>,')
        IP=$(echo "$INFO" | awk '/inet /{print $2; exit}')
        if echo "$STATE" | grep -q "UP"; then
            ok "$iface UP — $IP"
        else
            warn "$iface exists but is DOWN — run: sudo ip link set $iface up"
        fi
    fi
done

hdr "Disk space"
AVAIL=$(df -BG "$BASE_DIR" | awk 'NR==2{print $4}' | tr -d 'G')
[[ "$AVAIL" -gt 5 ]] && ok "${AVAIL}GB free" || fail "Low disk: only ${AVAIL}GB — logs may fill up"

hdr "Channel name cache"
CACHE="$BASE_DIR/logs/channel_names.json"
if [[ -f "$CACHE" ]]; then
    COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE'))))" 2>/dev/null || echo 0)
    ok "channel_names.json — $COUNT names cached"
else
    warn "No channel cache yet — names will be discovered on-site"
fi

echo ""
echo -e "${BLD}────────────────────────────────────────────${NC}"
echo -e "  ${GRN}PASSED${NC}: $PASS   ${RED}FAILED${NC}: $FAIL"
echo -e "${BLD}────────────────────────────────────────────${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Stack is NOT ready. Fix failures before leaving.${NC}"
    echo ""
    echo "Quick fix — restart everything:"
    echo "  cd ~/hotel-iptv && docker compose up -d"
    exit 1
else
    echo -e "${GRN}Stack is ready. Good luck on-site!${NC}"
    echo ""
    echo "On-site checklist:"
    echo "  1. sudo ip link set enp2s0 up              (bring up ethernet)"
    echo "  2. ./scripts/09_headend_discover.sh        (find CMP201AD IP)"
    echo "  3. sudo ./scripts/05_igmp_test.sh          (0 TVs — IGMP check)"
    echo "  4. sudo ./scripts/01_baseline_scan.sh enp2s0 60"
    echo "  5. Open http://localhost:3000              (Grafana)"
    echo "  6. Open http://192.168.1.10                (CMP201AD web GUI — admin/admin)"
    echo "  7. Turn on TVs in batches of 20"
fi
