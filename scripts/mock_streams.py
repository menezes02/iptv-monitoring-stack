#!/usr/bin/env python3
"""
Mock IPTV multicast stream generator.
Simulates 8 streams with realistic bitrates, jitter profiles, and burst loss.
"""

import socket
import struct
import time
import random
import threading
import sys

STREAMS = [
    # name, group, port, kbps, jitter_ms, burst_loss_prob, random_loss_pct
    ("BBC One",     "239.10.10.1", 1234, 4500, 2,  0.0,  0.5),   # clean
    ("CNN",         "239.10.10.2", 1235, 3800, 5,  0.0,  1.0),   # minor loss
    ("ESPN",        "239.10.10.3", 1236, 5200, 8,  0.02, 2.0),   # some burst
    ("Discovery",   "239.10.10.4", 1237, 4100, 3,  0.0,  0.5),   # clean
    ("HBO",         "239.10.10.5", 1238, 6000, 25, 0.05, 3.0),   # high jitter + burst
    ("Sky Sports",  "239.10.10.6", 1239, 5500, 12, 0.01, 1.5),   # moderate jitter
    ("Netflix OTT", "239.10.10.7", 1240, 8000, 4,  0.0,  0.5),   # clean, high bitrate
    ("Local News",  "239.10.10.8", 1241, 2800, 18, 0.03, 4.0),   # degraded
]

PACKET_SIZE = 1316
SEQ: dict[str, int] = {}
TS:  dict[str, int] = {}


def make_rtp(key: str, seq_offset: int = 0) -> bytes:
    seq = (SEQ.get(key, 0) + seq_offset) & 0xFFFF
    ts  = TS.get(key, 0)
    hdr = bytearray(12)
    hdr[0] = 0x80; hdr[1] = 0x21
    hdr[2] = (seq >> 8) & 0xFF; hdr[3] = seq & 0xFF
    hdr[4] = (ts >> 24) & 0xFF; hdr[5] = (ts >> 16) & 0xFF
    hdr[6] = (ts >> 8)  & 0xFF; hdr[7] = ts & 0xFF
    SEQ[key] = (seq + 1) & 0xFFFF
    TS[key]  = (ts + 3600) & 0xFFFFFFFF
    payload = bytes([0x47] + [random.randint(0, 255) for _ in range(PACKET_SIZE - 1)])
    return bytes(hdr) + payload


def stream_sender(name, group, port, kbps, jitter_ms, burst_prob, loss_pct, stop):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)

    pps      = kbps * 1000 / 8 / PACKET_SIZE
    interval = 1.0 / pps
    key      = f"{group}:{port}"
    in_burst = False
    burst_remaining = 0

    print(f"  {name:15s}  {group}:{port}  {kbps} kbps  jitter={jitter_ms}ms  burst={burst_prob*100:.0f}%")

    while not stop.is_set():
        # jitter: add random delay around the base interval
        jitter_sec = (random.gauss(0, jitter_ms / 1000)) if jitter_ms > 0 else 0
        sleep_time = max(0.0001, interval + jitter_sec)
        time.sleep(sleep_time)

        # burst loss logic
        if in_burst:
            burst_remaining -= 1
            if burst_remaining <= 0:
                in_burst = False
            SEQ[key] = (SEQ.get(key, 0) + 1) & 0xFFFF  # advance seq (simulate lost)
            continue

        if random.random() < burst_prob:
            in_burst = True
            burst_remaining = random.randint(3, 8)
            SEQ[key] = (SEQ.get(key, 0) + 1) & 0xFFFF
            continue

        # random single packet loss
        if random.random() < (loss_pct / 100):
            SEQ[key] = (SEQ.get(key, 0) + 1) & 0xFFFF
            continue

        try:
            sock.sendto(make_rtp(key), (group, port))
        except OSError:
            pass

    sock.close()


def main():
    print("=== Mock IPTV Stream Generator ===\n")
    stop = threading.Event()
    threads = []
    for name, group, port, kbps, jitter_ms, burst_prob, loss_pct in STREAMS:
        t = threading.Thread(
            target=stream_sender,
            args=(name, group, port, kbps, jitter_ms, burst_prob, loss_pct, stop),
            daemon=True,
        )
        t.start()
        threads.append(t)

    print(f"\n8 streams running. Ctrl-C to stop.\n")
    try:
        while True:
            time.sleep(5)
            sys.stdout.write(".")
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("\nStopping...")
        stop.set()


if __name__ == "__main__":
    main()
