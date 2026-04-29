#!/usr/bin/env bash
# Discover the Wellav CMP201AD headend on the local network.
# Tries the default management IP first, then scans the subnet.
# Saves the found IP to logs/headend_ip.txt for use by the SNMP exporter.

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$BASE_DIR/logs"
IP_FILE="$LOG_DIR/headend_ip.txt"
GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'

DEFAULT_IP="192.168.1.10"
SCAN_SUBNET="${1:-192.168.1}"   # override: ./09_headend_discover.sh 10.0.0

mkdir -p "$LOG_DIR"

echo -e "${BLD}CMP201AD Headend Discovery${NC}"
echo -e "Default IP: $DEFAULT_IP  |  Scan subnet: ${SCAN_SUBNET}.0/24\n"

# ------------------------------------------------------------------
# Try to identify an IP as the CMP201AD via HTTP (login page title)
# and SNMP sysDescr. Returns 0 if confirmed, 1 if not.
# ------------------------------------------------------------------
check_ip() {
    local ip="$1"

    # Quick ping first
    ping -c 1 -W 1 "$ip" &>/dev/null || return 1

    # HTTP check: the login page contains "CMP201AD"
    if curl -s --max-time 3 "http://$ip/" 2>/dev/null | grep -qi "CMP201AD\|CMP 201\|Wellav"; then
        echo -e "${GRN}✓${NC} $ip — CMP201AD confirmed via HTTP"
        return 0
    fi

    # SNMP fallback: check sysDescr for Wellav/CMP201AD
    if command -v snmpget &>/dev/null; then
        DESCR=$(snmpget -v2c -c public -t 3 -r 1 "$ip" 1.3.6.1.2.1.1.1.0 2>/dev/null || true)
        if echo "$DESCR" | grep -qi "CMP201AD\|Wellav\|media platform"; then
            echo -e "${GRN}✓${NC} $ip — CMP201AD confirmed via SNMP sysDescr"
            return 0
        fi
    fi

    # Fallback: device responds to ping + HTTP port 80 open — likely it
    if curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://$ip/" 2>/dev/null | grep -q "^[123]"; then
        echo -e "${YLW}?${NC} $ip — responds on HTTP port 80 (not confirmed as CMP201AD)"
        return 1
    fi

    return 1
}

# ------------------------------------------------------------------
# Step 1: Try default IP
# ------------------------------------------------------------------
echo "Trying default management IP $DEFAULT_IP ..."
if check_ip "$DEFAULT_IP"; then
    echo "$DEFAULT_IP" > "$IP_FILE"
    echo ""
    echo -e "${GRN}Headend found: $DEFAULT_IP${NC}"
    echo -e "Saved to: $IP_FILE"
    echo ""
    echo "Next steps:"
    echo "  docker compose up -d headend_exporter"
    echo "  curl http://localhost:9300/metrics | grep headend_"
    exit 0
fi

# ------------------------------------------------------------------
# Step 2: Scan subnet
# ------------------------------------------------------------------
echo ""
echo "Default IP not found. Scanning ${SCAN_SUBNET}.1–254 ..."
echo "(This may take 30–60 seconds)"
echo ""

FOUND=""

# Use nmap if available (fast), otherwise ping sweep
if command -v nmap &>/dev/null; then
    LIVE=$(nmap -sn "${SCAN_SUBNET}.0/24" --open 2>/dev/null | grep "Nmap scan report" | awk '{print $NF}' | tr -d '()')
else
    LIVE=""
    for i in $(seq 1 254); do
        ip="${SCAN_SUBNET}.$i"
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            LIVE="$LIVE $ip"
            echo -n "."
        fi
    done
    echo ""
fi

for ip in $LIVE; do
    if check_ip "$ip"; then
        FOUND="$ip"
        break
    fi
done

echo ""

if [[ -n "$FOUND" ]]; then
    echo "$FOUND" > "$IP_FILE"
    echo -e "${GRN}Headend found: $FOUND${NC}"
    echo -e "Saved to: $IP_FILE"
    echo ""
    echo "Next steps:"
    echo "  HEADEND_IP=$FOUND docker compose up -d headend_exporter"
    echo "  curl http://localhost:9300/metrics | grep headend_"
else
    echo -e "${RED}CMP201AD not found on ${SCAN_SUBNET}.0/24${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  • Connect laptop directly to CMP201AD management port (ports 1–2)"
    echo "  • Set laptop IP to 192.168.1.x (not .10) with gateway 192.168.1.254"
    echo "  • Run: ping 192.168.1.10"
    echo "  • Or pass a different subnet: $0 10.0.0"
    echo ""
    echo "Manual override: echo 'YOUR_IP' > $IP_FILE"
    exit 1
fi
