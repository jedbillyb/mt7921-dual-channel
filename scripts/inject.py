#!/usr/bin/env python3
"""Inject broadcast probe requests from a monitor vif with a made-up source MAC."""
import socket, struct, sys, time

iface = sys.argv[1]
src   = bytes.fromhex(sys.argv[2].replace(':',''))
n     = int(sys.argv[3]) if len(sys.argv) > 3 else 30

# minimal radiotap: version 0, pad 0, len 8, no present flags
radiotap = struct.pack('<BBHI', 0, 0, 8, 0)

bcast = b'\xff'*6
# 802.11 probe request: fc=0x0040, dur, da=bcast, sa=src, bssid=bcast, seq
def frame(seq):
    hdr = struct.pack('<HH', 0x0040, 0) + bcast + src + bcast + struct.pack('<H', seq << 4)
    ssid   = b'\x00\x00'                       # wildcard SSID
    rates  = b'\x01\x08\x0c\x12\x18\x24\x30\x48\x60\x6c'
    return radiotap + hdr + ssid + rates

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((iface, 0))
sent = 0
for i in range(n):
    try:
        s.send(frame(i))
        sent += 1
    except OSError as e:
        print(f"send failed at {i}: {e}")
        break
    time.sleep(0.1)
print(f"injected {sent}/{n} probe requests from {sys.argv[2]} on {iface}")
