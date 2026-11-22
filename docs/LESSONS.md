# What we tried, what failed, and why

The final design (wired Wake-on-LAN, a Pi as the always-on front door, idle detection on the PC)
is simple. Getting there was not. Here is every detour, in order, with the evidence. Several
of them may well work on *your* hardware, and knowing exactly where ours failed can save you an evening.

## Constraint that started it all

The PC sits where there is **no Ethernet cable** to the router, only Wi-Fi. A Raspberry Pi Zero W
is available, so the idea is that it sends the wake packets.

---

## 1. Wake-on-WLAN (WoWLAN) on the PC's Wi-Fi: ❌

The Intel AX201 advertises it:

```
$ iw phy | grep -A5 WoWLAN
WoWLAN support:
 * wake up on magic packet
 * wake up on pattern match ...
```

and ACPI lists the CNVi Wi-Fi as a wake source (`CNVW S4`). We enabled everything:
`nmcli ... 802-11-wireless.wake-on-wlan magic`, `iw phy0 wowlan enable magic-packet`, and
`power/wakeup=enabled` through a udev rule ([experiments/wowlan-setup.sh](../experiments/wowlan-setup.sh)).

The Pi sent the packet and the PC did not wake. On resume, from the RTC safety alarm:

```
iwlwifi 0000:00:14.3: Can't resume, device_powered_off() was called during wowlan
```

**The motherboard removes power from the integrated (CNVi) Wi-Fi in S3**, whatever Linux asks for.
We disabled Deep Sleep/ErP and enabled "PCIE Devices Power On": no change, and the BIOS has no
CNVi/WLAN wake option. A discrete PCIe/M.2 Wi-Fi card or a different board might behave
differently.

## 2. s2idle instead of S3: ❌ (works badly, costs too much)

With `mem_sleep = s2idle` the platform keeps more devices powered. But:

- the PC drew **70–80 W "asleep"**, more than its normal ~60 W idle and 20× the ~3.5 W of real S3. That defeats the purpose;
- it woke up on its own after ~70 s (ACPI SCI, IRQ 9), *before* the magic packet was even sent.

## 3. The Pi as a USB keyboard that wakes the PC: ❌

The Pi Zero was already plugged into the PC as a USB Ethernet gadget (an emergency network link).
A USB keyboard can wake a PC from S3 by sending a *remote wakeup* signal, and the BIOS had "USB
Keyboard/Remote Power On" enabled. So we rebuilt the gadget with configfs: network + HID keyboard,
`bmAttributes=0xa0` (remote wakeup). See
[experiments/usb-gadget-remote-wakeup.sh](../experiments/usb-gadget-remote-wakeup.sh).

The PC enumerated it and wakeup could be enabled on it and on the root hub
([experiments/usb-wake-host.rules](../experiments/usb-wake-host.rules)). It still never woke.

Writing to `/sys/class/udc/<udc>/srp` returned success, which looked promising. The kernel tracepoint
told the truth:

```
usb_gadget_wakeup: speed 3/3 state 7 250mA [...] --> -95     # EOPNOTSUPP
```

**The Linux `dwc2` gadget driver (the Pi's USB controller) does not implement remote wakeup**, and
sysfs swallows the error. A microcontroller with native USB (Pi Pico W, ESP32-S2/S3 with TinyUSB)
can do it. That remains a valid design if you cannot run a cable.

## 4. A cable from the Pi to the PC's Ethernet port: ❌ (with the hubs we had)

New idea: no cable to the router is possible, but a 30 cm cable from the Pi to the PC's own
Ethernet port is. The PC's NIC wakes on a magic packet, and the Pi sends it over that cable.
That needs a USB Ethernet adapter on the Pi, with the Pi's micro-USB port in host mode
(`dtoverlay=dwc2,dr_mode=host`).

- A micro-USB to USB-C cable into a USB-C hub with Ethernet: nothing enumerated. Those cables are
  built for the other direction (C side = host).
- With a proper adapter, the Pi saw only one device:

  ```
  ID 343c:0000 USB Type-C Digital AV Adapter   Class=Billboard
  ```

  That is the hub's *Billboard* chip, which only says "video alt-mode not supported". The actual
  hub and its Ethernet chip sit on the **USB 3** lines, and the Pi Zero is USB 2 only. External
  power to the hub did not change it.

A plain **USB 2.0** Ethernet adapter on a micro-USB OTG adapter would almost certainly have worked.
Then we found a way to run a cable to the router after all, which made this unnecessary.

## 5. Wired Wake-on-LAN to the router: ✅

`Supports Wake-on: pumbg`, `Wake-on: g`. First test: resume **9 s** after the Pi's magic packet,
wake IRQ from PCIe. Boring and reliable. This is the design in this repository.

---

## Things that bit us along the way

### NVIDIA refuses to suspend outside systemd

The first test "woke up after 3 s". In fact it never slept:

```
NVRM: ... PreserveVideoMemoryAllocations module parameter is set. System Power Management attempted
      without driver procfs suspend interface.
nvidia 0000:01:00.0: PM: pci_pm_suspend(): nv_pmops_suspend [nvidia] returns -5
PM: Some devices failed to suspend, or early wake event detected
```

`rtcwake -m mem` goes straight to the kernel and skips `nvidia-suspend.service`. Always suspend
with `systemctl suspend`. A bonus: VRAM (22 GB) is saved in ~16 s and restored on resume, and the
LLM server keeps running as if nothing happened.

### Our test script lied, several times

- It called "woke up in < 300 s" a success. The aborted suspend above (3 s) and the s2idle
  spontaneous wake (74 s) both passed as "woken by WoL".
- A test was started twice, so two delayed `wake-pc` jobs were queued on the Pi, and the resume time
  matched the wrong one.
- The fix to cancel stale jobs, `pkill -f 'sleep 90'`, ran inside a shell whose own command line
  contained `sleep 90`. It killed itself, so the packet was never sent.

The final [pc/test-wake.sh](../pc/test-wake.sh) logs the Pi's timestamp and only accepts a resume
within 30 s of it, with an RTC alarm as a safety net. **Timestamps or it didn't happen.**

### Root cannot suspend while you are logged in

`idle-watch` did its job after 30 minutes, and systemd said no:

```
suspend refused: User me is logged in on tty2.
Please retry operation after closing inhibitors and logging out other users.
```

None of the inhibitors were `block` locks (GNOME, NetworkManager and UPower only hold `delay` locks).
Fix: check for `block` sleep inhibitors yourself, then call `systemctl suspend -i`. Delay locks
(screen lock and so on) are still honoured.

### Two auto-suspends fight

GNOME already had "suspend after 30 min on AC" on. It only watches keyboard and mouse, so it would
suspend during a remote session. Turn it off and let `idle-watch` decide: it uses GNOME's idle hint
anyway.

### The desktop GPU is never at 0 %

The GPU driving the monitor idles at 8–17 % utilisation. `idle-watch` uses a 10 % threshold for
headless GPUs and 50 % for the display GPU.

### powertop turns Wake-on-LAN off

`powertop --auto-tune` at boot includes a "Wake-on-LAN status" tunable. A drop-in with
`ExecStartPost=ethtool -s <iface> wol g` puts WoL back on.

### Is a Pi Zero W too slow to be the front door?

We measured before committing: ~4.3 MB/s Pi↔PC over Wi-Fi, OpenSSL ChaCha20 at ~36 MB/s on the
ARMv6 core, `cloudflared` at ~33 MB RSS. Streaming tokens at ~50 tok/s is 10–20 KB/s. The only
noticeable cost is the web UI's first page load (a few MB of JS), and only once thanks to the
browser cache.

### `cloudflared tunnel route dns` used the wrong tunnel

Run inside `~/.cloudflared`, it picked the tunnel from the old `config.yml` and replied "already
configured". Pass `--config` and the tunnel UUID explicitly.

### FAT `/boot/firmware` on the Pi

We edited `config.txt`/`cmdline.txt` and rebooted, and the Pi came up with the *old* settings.
`sync` before `reboot`.
