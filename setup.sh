#!/usr/bin/env bash
# Full setup: install deps, start stack, launch mock streams, open Grafana
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'
ok()  { echo -e "${GRN}✓${NC} $*"; }
err() { echo -e "${RED}✗ $*${NC}"; }
hdr() { echo -e "\n${BLD}━━━ $* ━━━${NC}"; }

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR"

hdr "1 / 5  Install system dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq tcpdump ffmpeg docker.io docker-compose-v2 python3-pip
ok "System packages installed"

hdr "2 / 5  Docker group"
if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    ok "Added $USER to docker group"
    echo -e "${YLW}NOTE: You may need to run 'newgrp docker' or re-login if docker commands fail${NC}"
else
    ok "$USER already in docker group"
fi

hdr "3 / 5  Start monitoring stack"
# Use sudo docker in case group hasn't propagated yet
DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then
    DOCKER="sudo docker"
    echo "Using sudo docker (group not yet active in this shell)"
fi

$DOCKER compose up -d
ok "Stack started"

hdr "4 / 5  Wait for Prometheus + Grafana to be ready"
echo -n "Waiting for Grafana"
for i in $(seq 1 30); do
    if curl -s http://localhost:3000/api/health | grep -q '"ok"'; then
        echo ""
        ok "Grafana is up"
        break
    fi
    echo -n "."
    sleep 2
done

echo -n "Waiting for IPTV exporter"
for i in $(seq 1 20); do
    if curl -s http://localhost:9200/health | grep -q "ok"; then
        echo ""
        ok "IPTV exporter is up"
        break
    fi
    echo -n "."
    sleep 2
done

hdr "5 / 5  Launch mock IPTV streams (demo data for Grafana)"
echo "Starting 8 simulated streams in background..."
python3 "$BASE_DIR/scripts/mock_streams.py" &
MOCK_PID=$!
echo "$MOCK_PID" > "$BASE_DIR/logs/mock_streams.pid"
ok "Mock streams running (PID $MOCK_PID)"

sleep 12  # let exporter collect one full measurement window

hdr "Stack is ready"
echo ""
echo -e "  ${BLD}Grafana   ${NC}→  http://localhost:3000  (admin / iptv2024)"
echo -e "  ${BLD}Prometheus${NC}→  http://localhost:9090"
echo -e "  ${BLD}Metrics   ${NC}→  http://localhost:9200/metrics"
echo ""
echo "Opening Grafana in browser..."
xdg-open "http://localhost:3000/d/iptv-overview/iptv-stream-health" 2>/dev/null || \
    echo "Open manually: http://localhost:3000/d/iptv-overview/iptv-stream-health"
echo ""
echo -e "${YLW}To stop mock streams:${NC}  kill \$(cat logs/mock_streams.pid)"
echo -e "${YLW}To stop all services:${NC}  docker compose stop"
echo ""
