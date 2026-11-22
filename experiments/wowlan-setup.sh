#!/bin/bash
# EXPERIMENT 1 - Wake-on-WLAN (WoWLAN) on the PC's Wi-Fi card.  RESULT ON OUR HARDWARE: FAILED.
# The Intel AX201 (CNVi) advertises "wake up on magic packet" and everything below configures fine,
# but the motherboard cuts power to the CNVi Wi-Fi in S3. On resume the kernel says:
#   iwlwifi 0000:00:14.3: Can't resume, device_powered_off() was called during wowlan
# No BIOS option changed that (Deep Sleep off, PCIe wake on, ...). It may work on YOUR board,
# especially with a real PCIe/M.2 Wi-Fi card instead of an integrated CNVi one: worth 10 minutes.
set -e
WIFI_CONNECTION="${WIFI_CONNECTION:-MyWiFi}"    # NetworkManager profile of your Wi-Fi
WIFI_PCI="${WIFI_PCI:-0000:00:14.3}"            # lspci -D | grep -i network
iw phy | grep -A12 -i "WoWLAN support"           # must list "wake up on magic packet"
nmcli con mod "$WIFI_CONNECTION" 802-11-wireless.wake-on-wlan magic
iw phy0 wowlan enable magic-packet
# allow the card to wake the platform (ACPI), now and at every boot
echo enabled > /sys/bus/pci/devices/$WIFI_PCI/power/wakeup
echo "ACTION==\"add\", SUBSYSTEM==\"pci\", KERNEL==\"$WIFI_PCI\", ATTR{power/wakeup}=\"enabled\"" \
  > /etc/udev/rules.d/90-wowlan.rules
iw phy0 wowlan show
