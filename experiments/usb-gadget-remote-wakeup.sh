#!/bin/sh
# EXPERIMENT 3 - Pi Zero as a USB device that wakes the PC (USB "remote wakeup").  RESULT: FAILED.
# Idea: the Pi is plugged into the PC's USB port anyway (USB Ethernet gadget). A USB keyboard can
# wake a PC from S3 by sending a "remote wakeup" (resume) signal, so let the Pi pretend to be one.
# This configfs composite gadget (network ECM + HID boot keyboard, bmAttributes 0xa0 = remote wakeup)
# enumerates fine and the PC enables wakeup on it, BUT the Linux dwc2 gadget driver does not
# implement the wakeup operation. Tracing the gadget events shows:
#   usb_gadget_wakeup: ... --> -95   (EOPNOTSUPP)
# and writing /sys/class/udc/*/srp silently does nothing (the error is not returned to userspace).
# A Pi Pico W / ESP32-S2/S3 (TinyUSB) CAN do remote wakeup: that would be a valid alternative.
# Run as root on the Pi, with dtoverlay=dwc2,dr_mode=peripheral and WITHOUT g_ether loaded.
set -e
modprobe libcomposite
G=/sys/kernel/config/usb_gadget/pi
[ -d $G ] && exit 0
mkdir -p $G && cd $G
echo 0x1d6b > idVendor; echo 0x0104 > idProduct; echo 0x0100 > bcdDevice; echo 0x0200 > bcdUSB
mkdir -p strings/0x409 configs/c.1/strings/0x409
echo raspberrypi > strings/0x409/manufacturer
echo "Pi Zero net+kbd" > strings/0x409/product
echo "ECM+HID" > configs/c.1/strings/0x409/configuration
echo 0xa0 > configs/c.1/bmAttributes          # bus powered + REMOTE WAKEUP
echo 250  > configs/c.1/MaxPower
mkdir -p functions/ecm.usb0                    # network, fixed MACs so the PC interface name is stable
echo 02:55:00:00:00:01 > functions/ecm.usb0/host_addr
echo 02:55:00:00:00:02 > functions/ecm.usb0/dev_addr
mkdir -p functions/hid.usb0                    # boot-protocol keyboard
echo 1 > functions/hid.usb0/protocol; echo 1 > functions/hid.usb0/subclass; echo 8 > functions/hid.usb0/report_length
printf '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc
ln -s functions/ecm.usb0 configs/c.1/
ln -s functions/hid.usb0 configs/c.1/
ls /sys/class/udc | head -1 > UDC
# To try a wake-up while the PC sleeps:  echo 1 > /sys/class/udc/*/srp
# To see the real result:  echo 1 > /sys/kernel/tracing/events/gadget/usb_gadget_wakeup/enable; cat /sys/kernel/tracing/trace
