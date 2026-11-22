#!/usr/bin/env python3
"""Send a Wake-on-LAN magic packet (6 x 0xFF + 16 x MAC) by UDP broadcast.
Usage: wol.py AA:BB:CC:DD:EE:FF [broadcast-address]
Sent 3 times, to the subnet broadcast and 255.255.255.255, ports 9 and 7, to survive Wi-Fi losses."""
import socket, sys, time
mac = bytes.fromhex(sys.argv[1].replace(':', '').replace('-', ''))
bcast = sys.argv[2] if len(sys.argv) > 2 else '255.255.255.255'
pkt = b'\xff' * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    for dst in {bcast, '255.255.255.255'}:
        for port in (9, 7):
            s.sendto(pkt, (dst, port))
    time.sleep(1)
print(time.strftime('%F %T'), 'magic packet sent to', sys.argv[1])
