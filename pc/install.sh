#!/bin/bash
# PC side installer. Run with sudo from your normal user:  sudo ./pc/install.sh
# Edit the variables below first (or export them before running).
set -euo pipefail

PC_IP="${PC_IP:-192.168.1.10}"          # static LAN address of the PC (wired!)
PI_IP="${PI_IP:-192.168.1.20}"          # static LAN address of the Raspberry Pi
IFACE="${IFACE:-enp6s0}"                # wired interface that must wake the PC
NM_CONNECTION="${NM_CONNECTION:-Wired connection 1}"   # NetworkManager profile on that interface
WEBUI_PORT="${WEBUI_PORT:-8080}"        # Open WebUI (or any web UI) bound to 127.0.0.1
API_PORT="${API_PORT:-8082}"            # LLM API (OpenAI-compatible) bound to 127.0.0.1
IDLE_MINUTES="${IDLE_MINUTES:-30}"

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U="${SUDO_USER:?run with sudo from your normal user}"
UH=$(getent passwd "$U" | cut -d: -f6); UID_=$(id -u "$U")
HERE="$(cd "$(dirname "$0")/.." && pwd)"
sub() { sed -e "s/@PC_IP@/$PC_IP/g; s/@PI_IP@/$PI_IP/g; s/@WEBUI_PORT@/$WEBUI_PORT/g; s/@API_PORT@/$API_PORT/g; s/@IDLE_MINUTES@/$IDLE_MINUTES/g" "$1"; }

echo "== 1. Wake-on-LAN (magic packet) on $IFACE, persistent"
ethtool "$IFACE" | grep -q "Supports Wake-on:.*g" || { echo "$IFACE does not support magic packet WoL"; exit 1; }
nmcli con mod "$NM_CONNECTION" 802-3-ethernet.wake-on-lan magic
ethtool -s "$IFACE" wol g
if systemctl cat powertop.service >/dev/null 2>&1; then
  # powertop --auto-tune turns WoL off at boot: put it back right after
  mkdir -p /etc/systemd/system/powertop.service.d
  printf '[Service]\nExecStartPost=-/usr/sbin/ethtool -s %s wol g\n' "$IFACE" > /etc/systemd/system/powertop.service.d/keep-wol.conf
fi

echo "== 2. Firewall: only the Pi may reach the forwarded ports"
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow from "$PI_IP" to any port 18080,18082 proto tcp comment 'wake-on-demand Pi'
else
  echo "   (ufw not active: make sure nothing else exposes 18080/18082)"
fi

echo "== 3. LAN forwarder (user service) + activity file"
install -d -o "$U" -g "$U" "$UH/.local/lib/wake-on-demand" "$UH/.config/systemd/user"
install -m755 -o "$U" -g "$U" "$HERE/shared/tcpfwd.py" "$UH/.local/lib/wake-on-demand/tcpfwd.py"
sub "$HERE/pc/lanfwd.service" > "$UH/.config/systemd/user/lanfwd.service"; chown "$U:$U" "$UH/.config/systemd/user/lanfwd.service"
loginctl enable-linger "$U"
sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UID_ systemctl --user daemon-reload
sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UID_ systemctl --user enable --now lanfwd.service

echo "== 4. idle-watch (system service)"
install -m755 "$HERE/pc/idle-watch.py" /usr/local/sbin/idle-watch
sub "$HERE/pc/idle-watch.service" > /etc/systemd/system/idle-watch.service
systemctl daemon-reload
systemctl enable --now idle-watch.service

echo "== done"
ethtool "$IFACE" | grep -i "wake-on"
systemctl is-active idle-watch
sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UID_ systemctl --user is-active lanfwd
echo "Remember: disable your desktop's own automatic suspend (GNOME: Settings > Power > Automatic Suspend = Off)."
