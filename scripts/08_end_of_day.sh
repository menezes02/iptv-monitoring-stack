#!/usr/bin/env bash
# End-of-day pack-up — exports data, generates reports, prints checklist
# Usage: ./08_end_of_day.sh

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS="$BASE_DIR/reports"
LOGS="$BASE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPORT_DIR="$REPORTS/export_${TIMESTAMP}"

GRN='\033[0;32m'; YLW='\033[1;33m'; BLD='\033[1m'; NC='\033[0m'
ok()  { echo -e "${GRN}✓${NC} $*"; }
hdr() { echo -e "\n${BLD}=== $* ===${NC}"; }

mkdir -p "$EXPORT_DIR"

hdr "Generating case study report"
bash "$BASE_DIR/scripts/03_generate_cv_report.sh" 2>/dev/null && ok "Case study written"

hdr "Exporting Prometheus snapshot"
SNAP_RESP=$(curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot 2>/dev/null || echo "")
if echo "$SNAP_RESP" | grep -q "name"; then
    SNAP_NAME=$(echo "$SNAP_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['name'])" 2>/dev/null)
    ok "Prometheus snapshot: $SNAP_NAME"
    echo "  (stored in Prometheus data volume — accessible via docker cp)"
else
    echo -e "${YLW}  Snapshot failed — manual export: docker cp iptv_prometheus:/prometheus ./reports/prometheus_data${NC}"
fi

hdr "Copying key logs to export"
cp -f "$LOGS/metrics_snapshot.json" "$EXPORT_DIR/" 2>/dev/null && ok "metrics_snapshot.json"
cp -f "$LOGS/channel_names.json"    "$EXPORT_DIR/" 2>/dev/null && ok "channel_names.json"
cp -f "$LOGS/iptv_exporter.log"     "$EXPORT_DIR/" 2>/dev/null && ok "iptv_exporter.log"
cp -f "$REPORTS/baseline_report.md" "$EXPORT_DIR/" 2>/dev/null && ok "baseline_report.md" || true
find "$LOGS" -name "load_test_*.csv" -exec cp {} "$EXPORT_DIR/" \; 2>/dev/null && ok "load test CSVs" || true
find "$REPORTS" -name "case_study_*.md" -exec cp {} "$EXPORT_DIR/" \; 2>/dev/null && ok "case study" || true

hdr "Export complete"
ok "All data in: $EXPORT_DIR"
ls -lh "$EXPORT_DIR"

hdr "End-of-day checklist"
cat <<CHECKLIST

  Screenshots (do these NOW before closing laptop):
  □ Grafana dashboard — full view with all stream data
  □ Grafana — channel health table (zoom in)
  □ Grafana — packet loss graph over the full day
  □ Terminal dashboard output (./07_terminal_dashboard.sh — one frame)
  □ baseline_report.md open in terminal

  Files to push to GitHub tonight:
  □ git add -A && git commit -m "Hotel IPTV engagement — real data"
  □ git push

  LinkedIn:
  □ Post from reports/linkedin_post_draft.md
  □ Attach best Grafana screenshot

  CV update:
  □ Add bullet from reports/case_study_*.md
  □ Add "Prometheus · Grafana · UDP Multicast · IGMP" to skills if not there

  Stack (leave running or shut down):
  □ Leave running:  docker compose up -d   (auto-restarts if rebooted)
  □ Shut down:      docker compose stop

CHECKLIST

echo -e "${GRN}${BLD}Good work today.${NC}"
