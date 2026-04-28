#!/usr/bin/env python3
"""
IPTV Multicast Stream Prometheus Exporter
Measures per-stream: bitrate, packets/sec, packet loss, jitter, burst loss,
reorder rate, and uptime. Auto-discovers channel names from MPEG-TS SDT via ffprobe.
Exposes metrics on :9200 for Prometheus scraping.
"""

import socket
import struct
import threading
import time
import logging
import json
import os
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("/app/logs/iptv_exporter.log"),
    ],
)
log = logging.getLogger(__name__)

MULTICAST_BASE   = "239.10.10"
PORTS            = list(range(1234, 1251))
MEASURE_WINDOW   = 10
METRICS_PORT     = 9200
BUFFER_SIZE      = 65535
SOCKET_TIMEOUT   = 2.0
BURST_THRESHOLD  = 3
CHANNEL_CACHE    = "/app/logs/channel_names.json"
CHANNEL_MAP      = "/app/channel_map.json"

_lock = threading.Lock()

# ── Per-window counters ───────────────────────────────────────────────────────
_bytes_in_window:   dict[tuple, int]   = defaultdict(int)
_packets_in_window: dict[tuple, int]   = defaultdict(int)
_rtp_expected:      dict[tuple, int]   = defaultdict(int)
_rtp_received:      dict[tuple, int]   = defaultdict(int)
_burst_events:      dict[tuple, int]   = defaultdict(int)
_reorders:          dict[tuple, int]   = defaultdict(int)
_jitter_samples:    dict[tuple, list]  = defaultdict(list)

# ── Previous window snapshots ─────────────────────────────────────────────────
_bytes_prev:        dict[tuple, int]   = defaultdict(int)
_packets_prev:      dict[tuple, int]   = defaultdict(int)
_rtp_loss:          dict[tuple, float] = defaultdict(float)
_jitter_ms:         dict[tuple, float] = defaultdict(float)
_burst_prev:        dict[tuple, int]   = defaultdict(int)
_reorder_prev:      dict[tuple, int]   = defaultdict(int)

# ── Persistent state ──────────────────────────────────────────────────────────
_active_streams:    set[tuple]         = set()
_stream_first_seen: dict[tuple, float] = {}
_rtp_seq:           dict[tuple, int]   = {}
_last_arrival:      dict[tuple, float] = {}
_consecutive_lost:  dict[tuple, int]   = defaultdict(int)
_window_start = time.monotonic()

# ── Channel name discovery ────────────────────────────────────────────────────
_channel_names:     dict[tuple, str]   = {}   # key → "BBC One HD"
_discovery_pending: set[tuple]         = set() # keys with ffprobe in flight


def _load_channel_cache():
    """Load persisted channel names and manual overrides from disk on startup."""
    count = 0
    # Manual override map first (lower priority — auto-discovery overwrites)
    try:
        if os.path.exists(CHANNEL_MAP):
            with open(CHANNEL_MAP) as f:
                raw = json.load(f)
            for addr, name in raw.items():
                if addr.startswith("_") or not name:
                    continue
                group, port = addr.rsplit(":", 1)
                _channel_names[(group, int(port))] = name
                count += 1
            if count:
                log.info(f"Loaded {count} manual channel names from channel_map.json")
    except Exception as e:
        log.warning(f"Could not load channel_map.json: {e}")

    # Auto-discovery cache (higher priority — overwrites manual)
    try:
        if os.path.exists(CHANNEL_CACHE):
            with open(CHANNEL_CACHE) as f:
                raw = json.load(f)
            for addr, name in raw.items():
                group, port = addr.rsplit(":", 1)
                _channel_names[(group, int(port))] = name
                count += 1
            log.info(f"Loaded {len(raw)} cached channel names from channel_names.json")
    except Exception as e:
        log.warning(f"Could not load channel cache: {e}")


def _save_channel_cache():
    try:
        data = {f"{k[0]}:{k[1]}": v for k, v in _channel_names.items()}
        with open(CHANNEL_CACHE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        log.warning(f"Could not save channel cache: {e}")


def _discover_channel_name(key: tuple):
    """Run ffprobe in background to extract SDT service name."""
    group, port = key
    url = f"udp://@{group}:{port}?fifo_size=1000000&timeout=8000000"
    name = f"{group}:{port}"  # default fallback

    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json",
             "-show_programs", "-show_streams", url],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0 and result.stdout:
            data = json.loads(result.stdout)
            # Try SDT service_name from programs first
            for prog in data.get("programs", []):
                sname = prog.get("tags", {}).get("service_name", "").strip()
                if sname:
                    name = sname
                    break
            else:
                # Fall back to stream title tag
                for stream in data.get("streams", []):
                    title = stream.get("tags", {}).get("title", "").strip()
                    if title:
                        name = title
                        break
    except subprocess.TimeoutExpired:
        log.debug(f"ffprobe timeout on {group}:{port}")
    except FileNotFoundError:
        log.debug("ffprobe not available — channel names will use addresses")
    except Exception as e:
        log.debug(f"ffprobe error on {group}:{port}: {e}")

    with _lock:
        _channel_names[key] = name
        _discovery_pending.discard(key)
    _save_channel_cache()
    log.info(f"Channel name: {group}:{port} → \"{name}\"")


def _trigger_discovery(key: tuple):
    """Trigger one-shot channel name discovery if not already done."""
    if key in _channel_names or key in _discovery_pending:
        return
    _discovery_pending.add(key)
    t = threading.Thread(target=_discover_channel_name, args=(key,), daemon=True)
    t.start()


def channel_name(key: tuple) -> str:
    return _channel_names.get(key, f"{key[0]}:{key[1]}")


# ── Multicast socket ──────────────────────────────────────────────────────────

def join_multicast(sock: socket.socket, group: str, port: int) -> bool:
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        sock.bind((group, port))
        mreq = struct.pack("4sL", socket.inet_aton(group), socket.INADDR_ANY)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        return True
    except OSError as e:
        log.debug(f"Cannot join {group}:{port} — {e}")
        return False


def parse_rtp(data: bytes) -> tuple[int | None, int | None]:
    if len(data) < 12:
        return None, None
    if (data[0] >> 6) & 0x3 != 2:
        return None, None
    return int.from_bytes(data[2:4], "big"), int.from_bytes(data[4:8], "big")


def listen_stream(group: str, port: int):
    key = (group, port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.settimeout(SOCKET_TIMEOUT)

    if not join_multicast(sock, group, port):
        sock.close()
        return

    while True:
        try:
            data, _ = sock.recvfrom(BUFFER_SIZE)
            now = time.monotonic()
            seq, _ = parse_rtp(data)

            with _lock:
                first_packet = key not in _stream_first_seen
                _bytes_in_window[key]   += len(data)
                _packets_in_window[key] += 1
                _active_streams.add(key)

                if first_packet:
                    _stream_first_seen[key] = now
                    log.info(f"New stream detected: {group}:{port}")
                    _trigger_discovery(key)

                if key in _last_arrival:
                    delta_ms = (now - _last_arrival[key]) * 1000
                    _jitter_samples[key].append(delta_ms)
                    if len(_jitter_samples[key]) > 500:
                        _jitter_samples[key] = _jitter_samples[key][-500:]
                _last_arrival[key] = now

                if seq is not None:
                    if key in _rtp_seq:
                        delta = (seq - _rtp_seq[key]) & 0xFFFF
                        if delta == 0:
                            pass
                        elif delta < 0x8000:
                            lost = delta - 1
                            _rtp_expected[key] += delta
                            _rtp_received[key] += 1
                            if lost > 0:
                                _consecutive_lost[key] += lost
                                if _consecutive_lost[key] >= BURST_THRESHOLD:
                                    _burst_events[key] += 1
                                    _consecutive_lost[key] = 0
                            else:
                                _consecutive_lost[key] = 0
                        else:
                            _reorders[key]       += 1
                            _rtp_expected[key]   += 1
                            _rtp_received[key]   += 1
                    else:
                        _rtp_expected[key] += 1
                        _rtp_received[key] += 1
                    _rtp_seq[key] = seq

        except socket.timeout:
            with _lock:
                if key in _active_streams and _packets_in_window.get(key, 0) == 0:
                    _active_streams.discard(key)


# ── Window roller ─────────────────────────────────────────────────────────────

def _calc_jitter(samples: list[float]) -> float:
    if len(samples) < 2:
        return 0.0
    median = sorted(samples)[len(samples) // 2]
    return sum(abs(s - median) for s in samples) / len(samples)


def window_roller():
    global _window_start
    while True:
        time.sleep(MEASURE_WINDOW)
        with _lock:
            for key in list(_bytes_in_window.keys()):
                _bytes_prev[key]   = _bytes_in_window[key]
                _packets_prev[key] = _packets_in_window[key]
                _burst_prev[key]   = _burst_events[key]
                _reorder_prev[key] = _reorders[key]
                if _rtp_expected[key] > 0:
                    lost = _rtp_expected[key] - _rtp_received[key]
                    _rtp_loss[key] = max(0.0, lost / _rtp_expected[key] * 100)
                else:
                    _rtp_loss[key] = 0.0
                _jitter_ms[key]      = _calc_jitter(_jitter_samples[key][:])
                _rtp_expected[key]   = 0
                _rtp_received[key]   = 0
                _burst_events[key]   = 0
                _reorders[key]       = 0
                _jitter_samples[key] = []
            _bytes_in_window.clear()
            _packets_in_window.clear()
            _window_start = time.monotonic()

        snapshot = build_snapshot()
        with open("/app/logs/metrics_snapshot.json", "w") as f:
            json.dump(snapshot, f, indent=2)


# ── Snapshot + metrics ────────────────────────────────────────────────────────

def build_snapshot() -> dict:
    with _lock:
        now = time.monotonic()
        active = [
            {
                "group":           k[0],
                "port":            k[1],
                "channel":         channel_name(k),
                "bitrate_kbps":    round(_bytes_prev.get(k, 0) * 8 / MEASURE_WINDOW / 1000, 2),
                "packets_per_sec": round(_packets_prev.get(k, 0) / MEASURE_WINDOW, 2),
                "loss_pct":        round(_rtp_loss.get(k, 0.0), 2),
                "jitter_ms":       round(_jitter_ms.get(k, 0.0), 2),
                "burst_events":    _burst_prev.get(k, 0),
                "reorders":        _reorder_prev.get(k, 0),
                "uptime_sec":      round(now - _stream_first_seen[k], 0) if k in _stream_first_seen else 0,
            }
            for k in sorted(_active_streams)
        ]
    return {
        "timestamp":    datetime.utcnow().isoformat() + "Z",
        "active_count": len(active),
        "streams":      active,
    }


def prometheus_metrics() -> str:
    lines = []

    def g(name, help_text, typ="gauge"):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {typ}")

    with _lock:
        active_count = len(_active_streams)
        streams      = list(_active_streams)
        now          = time.monotonic()
        bpw    = dict(_bytes_prev)
        ppw    = dict(_packets_prev)
        loss   = dict(_rtp_loss)
        jitter = dict(_jitter_ms)
        burst  = dict(_burst_prev)
        reord  = dict(_reorder_prev)
        uptime = {k: now - v for k, v in _stream_first_seen.items()}
        names  = {k: channel_name(k) for k in streams}

    def lbl(k):
        ch = names.get(k, f"{k[0]}:{k[1]}")
        return f'multicast_group="{k[0]}",port="{k[1]}",channel="{ch}"'

    g("iptv_active_streams_total", "Number of active multicast streams detected")
    lines.append(f"iptv_active_streams_total {active_count}")

    g("iptv_stream_bitrate_kbps", "Stream bitrate in kbps over last measurement window")
    for k in streams:
        lines.append(f'iptv_stream_bitrate_kbps{{{lbl(k)}}} {bpw.get(k,0)*8/MEASURE_WINDOW/1000:.2f}')

    g("iptv_stream_packets_per_sec", "UDP packets per second per stream")
    for k in streams:
        lines.append(f'iptv_stream_packets_per_sec{{{lbl(k)}}} {ppw.get(k,0)/MEASURE_WINDOW:.2f}')

    g("iptv_stream_loss_percent", "RTP sequence-based packet loss percentage")
    for k in streams:
        lines.append(f'iptv_stream_loss_percent{{{lbl(k)}}} {loss.get(k,0.0):.2f}')

    g("iptv_stream_jitter_ms", "Packet interarrival jitter in milliseconds")
    for k in streams:
        lines.append(f'iptv_stream_jitter_ms{{{lbl(k)}}} {jitter.get(k,0.0):.2f}')

    g("iptv_stream_burst_events_total", "Burst loss events (>=3 consecutive lost packets) per window", "counter")
    for k in streams:
        lines.append(f'iptv_stream_burst_events_total{{{lbl(k)}}} {burst.get(k,0)}')

    g("iptv_stream_reorders_total", "Out-of-order RTP packet arrivals per window", "counter")
    for k in streams:
        lines.append(f'iptv_stream_reorders_total{{{lbl(k)}}} {reord.get(k,0)}')

    g("iptv_stream_uptime_seconds", "Seconds since first packet received on this stream")
    for k in streams:
        lines.append(f'iptv_stream_uptime_seconds{{{lbl(k)}}} {uptime.get(k,0):.0f}')

    g("iptv_exporter_up", "1 if the exporter is running")
    lines.append("iptv_exporter_up 1")

    return "\n".join(lines) + "\n"


# ── HTTP server ───────────────────────────────────────────────────────────────

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body = prometheus_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/channels":
            with _lock:
                data = {f"{k[0]}:{k[1]}": channel_name(k) for k in _active_streams}
                pending = [f"{k[0]}:{k[1]}" for k in _discovery_pending]
            body = json.dumps({"channels": data, "discovery_pending": pending}, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    log.info("IPTV Exporter starting — 239.10.10.1–20 ports 1234–1250")
    os.makedirs("/app/logs", exist_ok=True)
    _load_channel_cache()

    for last_octet in range(1, 21):
        group = f"{MULTICAST_BASE}.{last_octet}"
        for port in PORTS:
            t = threading.Thread(target=listen_stream, args=(group, port), daemon=True)
            t.start()

    threading.Thread(target=window_roller, daemon=True).start()

    log.info(f"Metrics  : http://0.0.0.0:{METRICS_PORT}/metrics")
    log.info(f"Channels : http://0.0.0.0:{METRICS_PORT}/channels")
    HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler).serve_forever()


if __name__ == "__main__":
    main()
