#!/usr/bin/env bash
# Phase 3: Decode a live multicast stream and log bitrate stability
# Usage: sudo ./02_stream_decoder_test.sh 239.10.10.1 1234 [duration_sec]

set -euo pipefail

GROUP="${1:-239.10.10.1}"
PORT="${2:-1234}"
DURATION="${3:-120}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$BASE_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DECODE_LOG="$LOG_DIR/decode_${GROUP//\./_}_${PORT}_${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"

command -v ffmpeg &>/dev/null  || { echo "ERROR: ffmpeg not installed"; exit 1; }
[[ $EUID -ne 0 ]] && echo "WARN: Not root — multicast join may fail without CAP_NET_ADMIN"

echo "=== Stream Decoder Test ==="
echo "Stream  : udp://@${GROUP}:${PORT}"
echo "Duration: ${DURATION}s"
echo "Log     : $DECODE_LOG"
echo ""

# ffmpeg reads the multicast stream and logs stats every second to file
# -vstats_file: per-frame video stats
# -progress pipe:1: machine-readable progress

timeout "$DURATION" ffmpeg \
    -i "udp://@${GROUP}:${PORT}?fifo_size=1000000&overrun_nonfatal=1" \
    -t "$DURATION" \
    -f null - \
    2>&1 | tee "$DECODE_LOG" || true

# Parse the log for bitrate samples
echo ""
echo "=== Bitrate Analysis ==="
if [[ -f "$DECODE_LOG" ]]; then
    grep "bitrate=" "$DECODE_LOG" | \
        awk -F'bitrate=' '{print $2}' | \
        awk '{print $1}' | \
        awk -v stream="${GROUP}:${PORT}" '
            BEGIN { sum=0; count=0; min=9999999; max=0 }
            /kbits/{
                val=$1+0
                sum+=val; count++
                if(val<min) min=val
                if(val>max) max=val
            }
            END {
                if(count>0) {
                    printf "Samples  : %d\n", count
                    printf "Avg kbps : %.1f\n", sum/count
                    printf "Min kbps : %.1f\n", min
                    printf "Max kbps : %.1f\n", max
                    printf "Variance : %.1f%%\n", (max-min)/(sum/count)*100
                } else {
                    print "No bitrate samples — stream may be undecodable"
                }
            }
        '

    # Check for decode errors
    ERRORS=$(grep -c "error\|corrupt\|invalid" "$DECODE_LOG" 2>/dev/null || echo 0)
    echo "Decode errors: $ERRORS"
fi

echo ""
echo "Log saved: $DECODE_LOG"
