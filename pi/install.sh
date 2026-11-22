#!/bin/bash
# Raspberry Pi side installer (tested on a Pi Zero W, Raspberry Pi OS Lite 13 "trixie", armhf).
# Run on the Pi:  sudo ./pi/install.sh
# The tunnel credentials JSON and /etc/cloudflared/config.yml are copied separately (see docs/GUIDE.md).
set -euo pipefail

PC_IP="${PC_IP:-192.168.1.10}"               # static LAN address of the PC
PC_MAC="${PC_MAC:-AA:BB:CC:DD:EE:FF}"        # MAC of the PC's WIRED interface (not the Wi-Fi one!)
BROADCAST="${BROADCAST:-192.168.1.255}"      # broadcast address of your LAN
PI_USER="${SUDO_USER:-pi}"

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ "$PC_MAC" != "AA:BB:CC:DD:EE:FF" ] || { echo "set PC_MAC first"; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
sub() { sed -e "s/@PC_IP@/$PC_IP/g; s/@PC_MAC@/$PC_MAC/g; s/@BROADCAST@/$BROADCAST/g; s/@PI_USER@/$PI_USER/g" "$1"; }

echo "== wake-pc + wake proxy"
install -d /usr/local/lib/wake-on-demand
install -m755 "$HERE/shared/tcpfwd.py" "$HERE/pi/wol.py" /usr/local/lib/wake-on-demand/
sub "$HERE/pi/wake-pc" > /usr/local/bin/wake-pc && chmod 755 /usr/local/bin/wake-pc
sub "$HERE/pi/wake-proxy.service" > /etc/systemd/system/wake-proxy.service

echo "== cloudflared (the official 'linux-arm' build runs on the ARMv6 Pi Zero W)"
if ! command -v cloudflared >/dev/null; then
  curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm
  chmod 755 /usr/local/bin/cloudflared
fi
cloudflared --version
install -m644 "$HERE/pi/cloudflared.service" /etc/systemd/system/cloudflared.service

systemctl daemon-reload
systemctl enable --now wake-proxy.service
if [ -f /etc/cloudflared/config.yml ]; then
  systemctl enable --now cloudflared.service
else
  echo "!! /etc/cloudflared/config.yml missing: copy it + the credentials JSON, then: sudo systemctl enable --now cloudflared"
fi
echo "== test the magic packet now (the PC is awake, nothing should happen):"
/usr/local/bin/wake-pc
