# Step-by-step guide

Placeholders used below. Replace them with your own values:

| Placeholder | Meaning | Example |
|---|---|---|
| `192.168.1.10` | PC, static, **wired** | |
| `192.168.1.20` | Raspberry Pi, static (Wi-Fi is fine) | |
| `192.168.1.255` | LAN broadcast address | |
| `AA:BB:CC:DD:EE:FF` | MAC of the PC's **wired** NIC | `ip link show enp6s0` |
| `enp6s0` | PC wired interface | |
| `homelab.example` | your domain on Cloudflare | |
| `chat.` / `llm.` | public hostnames for the web UI / the API | |

Time needed: about 1–2 hours, most of it testing.

---

## 0. Five-minute feasibility check (do this first)

On the PC:

```bash
sudo ethtool enp6s0 | grep -i wake      # need "Supports Wake-on: ...g..."  (g = magic packet)
cat /sys/power/mem_sleep                # "[deep]" = S3 available. Only "[s2idle]" = see LESSONS.md
grep PXSX /proc/acpi/wakeup             # the NIC's PCIe port should be able to wake (S3/S4)
```

Then try a manual round trip **before** installing anything:

```bash
# PC: go to sleep
systemctl suspend
# from another machine on the LAN (the Pi, a laptop...):
python3 pi/wol.py AA:BB:CC:DD:EE:FF 192.168.1.255
```

If the PC comes back, everything else in this guide is plumbing. If it does not, fix this first:
check the BIOS settings below and make sure the cable is plugged in.

## 1. BIOS / UEFI

Names vary between vendors. These are the ones on an ASRock-style BIOS:

| Setting | Value | Why |
|---|---|---|
| Advanced → ACPI → **Suspend to RAM** | Auto / Enabled | S3 must exist |
| Advanced → ACPI → **PCIE Devices Power On** (Wake on LAN, PME) | Enabled | lets the NIC wake the system |
| Advanced → Chipset → **Deep Sleep** / ErP / EuP | **Disabled** | ErP cuts standby power to the NIC |
| Advanced → ACPI → USB Mouse Power On | Disabled (optional) | a bumped mouse will not wake the PC |
| Advanced → Chipset → Restore on AC Power Loss | Power On (optional) | the box comes back after a power cut |

## 2. Network

- The PC needs a **cable** to the router. Wi-Fi wake (WoWLAN) did not survive S3 on our board;
  details are in LESSONS.md.
- Give the PC and the Pi **static addresses**: DHCP reservations on the router, or NetworkManager
  `ipv4.method manual`.
- The Pi can stay on Wi-Fi: it only sends broadcast packets and forwards a few KB/s.

## 3. PC: make sure suspend itself is healthy

```bash
systemctl suspend          # wake it with the power button, then:
journalctl -k -b | grep -E "PM: suspend|failed to suspend"
```

### NVIDIA notes

- Check `cat /proc/driver/nvidia/params | grep Preserve` → `PreserveVideoMemoryAllocations: 1`.
  This makes the driver save VRAM before sleep, so your model stays loaded.
- `nvidia-suspend.service` and `nvidia-resume.service` must be enabled. They only run when you
  suspend **through systemd**.
- VRAM is saved to `NVreg_TemporaryFilePath`, often `/var`. See below for what that means for your SSD.

### Does saving VRAM wear out the SSD?

**Every suspend writes the content of VRAM to disk.** With a model loaded on 2 × 12 GB GPUs, that is
~22 GB per suspend in our case: the dump takes ~16 s, is read back on resume and then deleted.
Flash memory has a finite write endurance, so it is a fair question. Here are the numbers for our
drive, a 1 TB consumer NVMe (Crucial P5 Plus) rated at **600 TBW** (terabytes written, the
warranty figure):

| Suspends per day | Written by VRAM dumps per year | Years to reach 600 TBW |
|---|---|---|
| 1 | ~8 TB | ~75 |
| 2 | ~16 TB | ~37 |
| 5 | ~40 TB | ~15 |
| 10 | ~80 TB | ~7.5 |
| 20 | ~160 TB | ~3.7 |

With a 30-minute idle timeout, a realistic day has a handful of suspend cycles, so **the VRAM dumps
alone would take well over a decade** to use up the rated endurance.

**Real data from our drive** (`nvme smart-log`, S3 hours do not count as power-on hours):

| | |
|---|---|
| Power-on hours | 138 |
| Data written over the drive's life | 4.29 TB, ≈ 0.7 % of 600 TBW, almost all of it from the setup phase (fio disk benchmarks, several large model downloads, model copies) |
| `percentage_used` reported by the drive | 0 % |
| Steady state after setup, **everything included** (VRAM dumps, logs, apps) | ~46 GB/day (152 GB in 3.3 days) → ~17 TB/year → ~35 years to 600 TBW |

The one-off setup wrote far more than months of daily suspend cycles will. Downloading one big model
costs more endurance than a week of sleeping. The rest of your writes (model
downloads, Docker, logs...) come on top, so check your own budget:

```bash
sudo apt install nvme-cli                # not installed by default on Ubuntu
sudo nvme smart-log /dev/nvme0 | grep -E "data_units_written|percentage_used"
# data_units_written x 512,000 bytes = total written over the drive's life

# no root / nothing to install: writes since the last boot (in GB)
awk '{printf "%.1f GB\n", $7*512/1e9}' /sys/block/nvme0n1/stat
```

Rules of thumb:

- the cost scales with **VRAM in use × suspends per day**: a single 8 GB card with a small model
  writes a third of our figure;
- 1 TB consumer drives are typically rated 600–700 TBW and 2 TB drives about twice that; drives
  usually outlive their rating, but that is not guaranteed;
- many very short sleep/wake cycles are the worst case, so do not set the idle timeout to a few minutes.

**Zero-wear option: keep the dump in RAM.** S3 means *suspend to RAM*: RAM stays powered while the
PC sleeps, so the dump does not need a disk at all. If you have enough free RAM (at least the VRAM in
use, ~22 GB here, on top of what your apps need), point the driver at a tmpfs and reboot:

```bash
echo 'options nvidia NVreg_TemporaryFilePath=/dev/shm' | sudo tee /etc/modprobe.d/nvidia-vram-tmpfs.conf
sudo update-initramfs -u    # the nvidia module may be loaded from the initramfs
```

Trade-offs: this needs that much free RAM at suspend time (otherwise the dump fails or hits swap,
which is on disk anyway), and it is **incompatible with hibernation (S4)**, where RAM is powered off.
If power is lost during sleep, everything in RAM is lost, but that happens with or without this
option. We kept the disk default: at our usage the wear is negligible, and RAM is better spent on
models.

Turn **off** the desktop's own automatic suspend: GNOME Settings → Power → Automatic Suspend → Off
(`gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'`).
`idle-watch` replaces it and also knows about remote use.

## 4. Raspberry Pi

1. Flash Raspberry Pi OS Lite, enable SSH, and give it a static IP.
2. Copy this repository to the Pi and install:

   ```bash
   sudo PC_IP=192.168.1.10 PC_MAC=AA:BB:CC:DD:EE:FF BROADCAST=192.168.1.255 ./pi/install.sh
   ```

   This installs `/usr/local/bin/wake-pc`, the `wake-proxy` service (listening on `127.0.0.1:18080`
   and `:18082`) and the `cloudflared` binary.
3. Power the Pi from something that stays on. A PC USB port is fine **if** the board keeps USB
   powered in S3: ours did, and the Pi survived hours of PC sleep.

## 5. Prove Wake-on-LAN with timestamps

From the PC (set up an SSH key to the Pi first):

```bash
sudo PI=pi@192.168.1.20 ./pc/test-wake.sh
```

The script suspends the PC through systemd and asks the Pi to send the magic packet 90 s later.
An RTC alarm wakes the PC after 600 s anyway, so a failed test never leaves it asleep. You want:

```
Pi wake-pc: 1794841858  resume: 1794841867
==> WOKEN BY THE PI (9 s after the magic packet)
```

Do not touch the keyboard or mouse during the test.

## 6. PC services

```bash
sudo PC_IP=192.168.1.10 PI_IP=192.168.1.20 IFACE=enp6s0 \
     NM_CONNECTION="Wired connection 1" WEBUI_PORT=8080 API_PORT=8082 IDLE_MINUTES=30 \
     ./pc/install.sh
```

The installer does four things:

1. Makes Wake-on-LAN persistent: NetworkManager `wake-on-lan magic`, plus a powertop drop-in,
   because `powertop --auto-tune` switches WoL off at boot.
2. Adds a ufw rule: only the Pi may connect to 18080/18082.
3. Installs `lanfwd`, a **user** service that runs `tcpfwd.py lan`. Your web UI and API stay bound
   to `127.0.0.1`; the forwarder exposes them to the Pi alone and writes
   `/run/user/<uid>/wake-activity` whenever real traffic passes (≥ 512-byte chunks, so WebSocket
   pings do not count).
4. Installs `idle-watch`, a **system** service.

Check that it works:

```bash
journalctl -u idle-watch -f
# idle-watch: suspend after 30 min of inactivity
# busy: graphical session 2 active
```

Try it with `DRY_RUN=1` first by adding `Environment=DRY_RUN=1` to the unit.

## 7. Cloudflare Tunnel on the Pi

You need a domain on Cloudflare, Zero Trust (the free plan is fine) and `cloudflared` logged in on
a machine with a browser (`cloudflared tunnel login`).

1. Create a dedicated tunnel for the Pi:

   ```bash
   cloudflared tunnel create homelab-pi     # writes <TUNNEL_ID>.json, the tunnel credentials
   ```

2. Create Access applications for `chat.homelab.example` and `llm.homelab.example` in Zero Trust:
   - an email-login policy for you;
   - a **Service Auth** policy with a service token for non-browser clients (coding agents, scripts).
   Note each application's **AUD tag**.
3. Write `/etc/cloudflared/config.yml` on the Pi from `pi/cloudflared-config.example.yml`. It
   points to the wake proxy and sets `originRequest.access`, so `cloudflared` itself rejects any
   request without a valid Access JWT. Copy the credentials JSON next to it with mode `600`.
4. `sudo systemctl enable --now cloudflared` on the Pi. The log should show 4× `Registered tunnel connection`.
5. Route DNS to the **new** tunnel. Pass the config/ID explicitly: inside a folder with an old
   `config.yml`, `cloudflared` silently uses the old tunnel.

   ```bash
   cloudflared --config pi-config.yml tunnel route dns --overwrite-dns <TUNNEL_ID> chat.homelab.example
   cloudflared --config pi-config.yml tunnel route dns --overwrite-dns <TUNNEL_ID> llm.homelab.example
   ```

6. If the PC used to run its own tunnel for these hostnames, remove them from it. SSH can stay
   there: it is only reachable while the PC is awake, which is fine.

Clients call the API with the Access service token headers (`CF-Access-Client-Id`,
`CF-Access-Client-Secret`) plus the API key of your LLM server.

## 8. End-to-end test

1. `systemctl suspend` on the PC.
2. On your phone **with Wi-Fi off**, open `https://chat.homelab.example`.
3. On the Pi: `journalctl -u wake-proxy -f`

   ```
   PC not reachable on 192.168.1.10:18080 -> sending magic packet
   PC ready after 14s
   ```

## 9. Day-to-day

| I want to... | Command |
|---|---|
| keep the PC awake during a long job | `systemd-inhibit --what=sleep --mode=block <command>` |
| wake it by hand | `ssh pi@192.168.1.20 wake-pc` |
| see why it is (not) sleeping | `journalctl -u idle-watch` |
| see wake-ups | `journalctl -u wake-proxy` (on the Pi) |
| change the idle time | `Environment=IDLE_MINUTES=…` in `/etc/systemd/system/idle-watch.service` |

An open browser tab of the web UI will wake the PC when it refreshes, for example when you unlock
your phone. We kept this on purpose: the PC is ready by the time you start typing. If you do not
want it, close the tab.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `nv_pmops_suspend returns -5`, suspend aborted after 3 s | suspended outside systemd (`rtcwake -m mem`, `/sys/power/state`). Use `systemctl suspend`. |
| idle-watch log: `suspend refused: User X is logged in` | old version: use `systemctl suspend -i` (this repo does) |
| PC sleeps while you use it remotely | the desktop's own auto-suspend is still on |
| Woken by the RTC alarm, not the Pi | WoL is off (`ethtool enp6s0`: `Wake-on: d`, powertop?), ErP/Deep Sleep is on, the cable is unplugged, or the wrong MAC (Wi-Fi instead of Ethernet) |
| Wakes up by itself | `cat /sys/power/pm_wakeup_irq`; USB devices with `power/wakeup=enabled`; BIOS "USB Mouse Power On" |
| Edited files in `/boot/firmware` on the Pi and nothing changed after reboot | it is FAT: run `sync` before rebooting |
