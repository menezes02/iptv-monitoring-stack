#!/usr/bin/env python3
"""
CMP201AD Headend SNMP Exporter
Polls Wellav CMP201AD via SNMP v2c and HTTP health check.
Exposes Prometheus metrics on port 9300.

Env vars:
  HEADEND_IP       default 192.168.1.10
  SNMP_COMMUNITY   default public
  POLL_INTERVAL    default 30 (seconds)
  EXPORTER_PORT    default 9300
  LOG_DIR          default /app/logs
"""

import os, time, json, threading, logging, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("headend")

HEADEND_IP     = os.environ.get("HEADEND_IP", "192.168.1.10")
SNMP_COMMUNITY = os.environ.get("SNMP_COMMUNITY", "public")
POLL_INTERVAL  = int(os.environ.get("POLL_INTERVAL", "30"))
EXPORTER_PORT  = int(os.environ.get("EXPORTER_PORT", "9300"))
LOG_DIR        = Path(os.environ.get("LOG_DIR", "/app/logs"))

_metrics: dict = {}
_lock = threading.Lock()

# ---------------------------------------------------------------------------
# SNMP helpers
# ---------------------------------------------------------------------------

def _snmp_engine():
    from pysnmp.hlapi import SnmpEngine, CommunityData, UdpTransportTarget, ContextData
    return SnmpEngine(), CommunityData(SNMP_COMMUNITY, mpModel=1), \
           UdpTransportTarget((_load_headend_ip(), 161), timeout=5, retries=1), \
           ContextData()


def snmp_get(oids: list) -> dict:
    try:
        from pysnmp.hlapi import getCmd, ObjectType, ObjectIdentity
        eng, community, transport, ctx = _snmp_engine()
        objs = [ObjectType(ObjectIdentity(oid)) for oid in oids]
        err_ind, err_stat, _, var_binds = next(
            getCmd(eng, community, transport, ctx, *objs)
        )
        if err_ind or err_stat:
            return {}
        return {str(vb[0]): vb[1] for vb in var_binds}
    except Exception as e:
        log.debug("snmp_get error: %s", e)
        return {}


def snmp_walk(base_oid: str) -> dict:
    try:
        from pysnmp.hlapi import nextCmd, ObjectType, ObjectIdentity
        eng, community, transport, ctx = _snmp_engine()
        results = {}
        for err_ind, err_stat, _, var_binds in nextCmd(
            eng, community, transport, ctx,
            ObjectType(ObjectIdentity(base_oid)),
            lexicographicMode=False,
        ):
            if err_ind or err_stat:
                break
            for vb in var_binds:
                results[str(vb[0])] = vb[1]
        return results
    except Exception as e:
        log.debug("snmp_walk error: %s", e)
        return {}


def _idx(oid: str) -> str:
    return oid.split(".")[-1]

# ---------------------------------------------------------------------------
# HTTP health check (just reachability — no auth needed to hit the root page)
# ---------------------------------------------------------------------------

def http_check(ip: str) -> int:
    try:
        import urllib.request
        req = urllib.request.urlopen(f"http://{ip}/", timeout=3)
        return 1 if req.status < 500 else 0
    except Exception:
        return 0

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

def poll():
    ip = _load_headend_ip()
    new: dict = {"headend_ip": ip, "ts": time.time()}

    sys_data = snmp_get([
        "1.3.6.1.2.1.1.1.0",  # sysDescr
        "1.3.6.1.2.1.1.3.0",  # sysUpTime (1/100 s)
        "1.3.6.1.2.1.1.5.0",  # sysName
        "1.3.6.1.2.1.1.6.0",  # sysLocation
    ])

    if not sys_data:
        new["up"] = 0
        log.warning("Headend %s unreachable via SNMP", ip)
    else:
        new["up"] = 1
        uptime_raw = next(
            (v for k, v in sys_data.items() if "sysUpTime" in k), None
        )
        new["uptime_seconds"] = int(uptime_raw) / 100 if uptime_raw is not None else 0
        new["sys_descr"]    = str(next((v for k, v in sys_data.items() if "sysDescr" in k), ""))
        new["sys_name"]     = str(next((v for k, v in sys_data.items() if "sysName" in k), ""))
        new["sys_location"] = str(next((v for k, v in sys_data.items() if "sysLocation" in k), ""))
        log.info("Headend up: %s  uptime %.0fs", new["sys_name"] or ip, new["uptime_seconds"])

    # Interface table
    if new.get("up"):
        ifaces: dict = {}

        for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.2").items():    # ifDescr
            ifaces.setdefault(_idx(oid), {})["descr"] = str(val)
        for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.8").items():    # ifOperStatus
            ifaces.setdefault(_idx(oid), {})["oper_status"] = int(val)
        for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.14").items():   # ifInErrors
            ifaces.setdefault(_idx(oid), {})["rx_errors"] = int(val)
        for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.20").items():   # ifOutErrors
            ifaces.setdefault(_idx(oid), {})["tx_errors"] = int(val)

        # Prefer 64-bit HC counters; fall back to 32-bit
        hc_in  = snmp_walk("1.3.6.1.2.1.31.1.1.1.6")   # ifHCInOctets
        hc_out = snmp_walk("1.3.6.1.2.1.31.1.1.1.10")  # ifHCOutOctets
        speed  = snmp_walk("1.3.6.1.2.1.31.1.1.1.15")  # ifHighSpeed (Mbps)

        if hc_in:
            for oid, val in hc_in.items():
                ifaces.setdefault(_idx(oid), {})["rx_bytes"] = int(val)
            for oid, val in hc_out.items():
                ifaces.setdefault(_idx(oid), {})["tx_bytes"] = int(val)
            for oid, val in speed.items():
                ifaces.setdefault(_idx(oid), {})["speed_mbps"] = int(val)
        else:
            for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.10").items():  # ifInOctets
                ifaces.setdefault(_idx(oid), {})["rx_bytes"] = int(val)
            for oid, val in snmp_walk("1.3.6.1.2.1.2.2.1.16").items():  # ifOutOctets
                ifaces.setdefault(_idx(oid), {})["tx_bytes"] = int(val)

        new["interfaces"] = ifaces

    new["http_reachable"] = http_check(ip)

    with _lock:
        _metrics.clear()
        _metrics.update(new)

    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "headend_state.json").write_text(json.dumps(new, indent=2, default=str))
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Prometheus metrics renderer
# ---------------------------------------------------------------------------

def render_metrics() -> str:
    with _lock:
        m = dict(_metrics)

    if not m:
        return "# waiting for first poll\n"

    ip  = m.get("headend_ip", HEADEND_IP)
    out = []

    def line(s: str):
        out.append(s)

    line('# HELP headend_up 1 if headend responds to SNMP')
    line('# TYPE headend_up gauge')
    line(f'headend_up{{ip="{ip}"}} {m.get("up", 0)}')

    line('# HELP headend_http_reachable 1 if web GUI is reachable on port 80')
    line('# TYPE headend_http_reachable gauge')
    line(f'headend_http_reachable{{ip="{ip}"}} {m.get("http_reachable", 0)}')

    line('# HELP headend_last_poll_timestamp_seconds Unix timestamp of last poll')
    line('# TYPE headend_last_poll_timestamp_seconds gauge')
    line(f'headend_last_poll_timestamp_seconds{{ip="{ip}"}} {m.get("ts", 0):.0f}')

    if m.get("up"):
        descr = m.get("sys_descr", "").replace('"', "'")[:80]
        name  = m.get("sys_name",  "").replace('"', "'")
        loc   = m.get("sys_location", "").replace('"', "'")

        line('# HELP headend_info Static device information (always 1)')
        line('# TYPE headend_info gauge')
        line(f'headend_info{{ip="{ip}",sys_name="{name}",sys_descr="{descr}",location="{loc}"}} 1')

        line('# HELP headend_uptime_seconds Device uptime in seconds')
        line('# TYPE headend_uptime_seconds gauge')
        line(f'headend_uptime_seconds{{ip="{ip}"}} {m.get("uptime_seconds", 0):.0f}')

        ifaces = m.get("interfaces", {})
        if ifaces:
            line('# HELP headend_interface_up Interface operational status (1=up, 0=down)')
            line('# TYPE headend_interface_up gauge')
            line('# HELP headend_interface_rx_bytes_total Interface receive bytes (counter)')
            line('# TYPE headend_interface_rx_bytes_total counter')
            line('# HELP headend_interface_tx_bytes_total Interface transmit bytes (counter)')
            line('# TYPE headend_interface_tx_bytes_total counter')
            line('# HELP headend_interface_rx_errors_total Interface receive errors (counter)')
            line('# TYPE headend_interface_rx_errors_total counter')
            line('# HELP headend_interface_tx_errors_total Interface transmit errors (counter)')
            line('# TYPE headend_interface_tx_errors_total counter')
            line('# HELP headend_interface_speed_mbps Interface speed in Mbps')
            line('# TYPE headend_interface_speed_mbps gauge')

            for idx, iface in sorted(ifaces.items(), key=lambda x: int(x[0])):
                ifname = iface.get("descr", f"if{idx}").replace('"', "'")
                lbl = f'ip="{ip}",ifindex="{idx}",ifname="{ifname}"'
                oper = iface.get("oper_status")
                if oper is not None:
                    line(f'headend_interface_up{{{lbl}}} {1 if oper == 1 else 0}')
                if "rx_bytes" in iface:
                    line(f'headend_interface_rx_bytes_total{{{lbl}}} {iface["rx_bytes"]}')
                if "tx_bytes" in iface:
                    line(f'headend_interface_tx_bytes_total{{{lbl}}} {iface["tx_bytes"]}')
                if "rx_errors" in iface:
                    line(f'headend_interface_rx_errors_total{{{lbl}}} {iface["rx_errors"]}')
                if "tx_errors" in iface:
                    line(f'headend_interface_tx_errors_total{{{lbl}}} {iface["tx_errors"]}')
                if "speed_mbps" in iface:
                    line(f'headend_interface_speed_mbps{{{lbl}}} {iface["speed_mbps"]}')

    return "\n".join(out) + "\n"

# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/metrics", "/"):
            body = render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass

# ---------------------------------------------------------------------------
# IP discovery helper
# ---------------------------------------------------------------------------

def _load_headend_ip() -> str:
    ip_file = LOG_DIR / "headend_ip.txt"
    if ip_file.exists():
        ip = ip_file.read_text().strip()
        if ip:
            return ip
    return HEADEND_IP

# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------

def poll_loop():
    while True:
        try:
            poll()
        except Exception as e:
            log.error("Poll error: %s", e)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    ip = _load_headend_ip()
    log.info("Headend exporter starting — target: %s  port: %d  interval: %ds",
             ip, EXPORTER_PORT, POLL_INTERVAL)

    try:
        from pysnmp.hlapi import getCmd  # noqa: F401
        log.info("pysnmp available — SNMP polling enabled")
    except ImportError:
        log.warning("pysnmp not found — SNMP metrics will be unavailable. "
                    "Install: pip install pysnmp")

    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()

    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), Handler)
    log.info("Listening on :%d  — /metrics  /health", EXPORTER_PORT)
    server.serve_forever()
