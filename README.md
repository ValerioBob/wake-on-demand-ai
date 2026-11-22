# Wake-on-Demand Local AI Server

Run your local LLM **only when you actually use it**: ~60 W idle becomes ~3–4 W asleep.
The PC sleeps (suspend-to-RAM, S3) after 30 idle minutes. A Raspberry Pi Zero W that is always on
(it draws about 1 W) receives your requests from the internet, wakes the PC with a Wake-on-LAN
magic packet, waits until the AI is ready and forwards the request. The model **stays in VRAM**
across sleep, so there is no 1-minute model reload.

Your phone, your coding agent, Open WebUI: none of them need to know the PC was asleep. The first
request just takes ~15 s longer.

```
   phone / laptop / coding agent
                 │  https://chat.homelab.example   https://llm.homelab.example
                 ▼
        ┌─────────────────┐
        │ Cloudflare      │  Zero Trust Access (login / service token)
        │ Access + Tunnel │
        └────────┬────────┘
                 │ outbound tunnel (no open ports at home)
═════════════════│════════════════════════════ home LAN ═══════════════════════
                 ▼
   ┌───────────────────────────────┐
   │ Raspberry Pi Zero W (~1 W)    │
   │  cloudflared                  │
   │     │                         │
   │     ▼                         │
   │  wake proxy (tcpfwd.py wake)  │
   │   1. PC answers? ── yes ──────┼──────────────────┐
   │   2. no → magic packet ───────┼──┐               │
   │   3. retry until it answers   │  │ Wake-on-LAN   │ TCP (HTTP, SSE, WebSocket)
   └───────────────────────────────┘  │ (UDP bcast)   │
                                      ▼               ▼
                 ┌────────────────────────────────────────────────┐
                 │ AI PC  (wired Ethernet: WoL works from S3)     │
                 │  tcpfwd.py lan  :18080/:18082  (Pi only)       │
                 │     └─► Open WebUI 127.0.0.1:8080              │
                 │     └─► LLM API    127.0.0.1:8082              │
                 │  idle-watch: 30 min without traffic, GPU work, │
                 │  SSH or a local user → systemctl suspend       │
                 └────────────────────────────────────────────────┘
```

## Why

A local AI spends most of the day doing nothing. Mine draws **~60 W at the wall when idle**,
with two GPUs holding a model in VRAM, fans spinning and the PSU warm. The idle figure could
certainly be tuned further, but that is not the point. Every idle hour burns energy and adds
power-on hours to fans, GPUs, PSU and SSD **for no actual use**.

With this setup the same machine draws **~3–4 W at the wall while asleep**. That figure
**includes the Raspberry Pi**, which is powered from one of the PC's USB ports that stays on in S3.
The front door to the AI is paid for out of those 3–4 W.

| Scenario (wall power, measured) | Power | Energy per day | Energy per year |
|---|---|---|---|
| Always on, idle | ~60 W | 1.44 kWh | ~526 kWh |
| Always asleep (PC in S3 + Pi) | ~3.5 W | 0.08 kWh | ~31 kWh |
| **Example: used 4 h/day, asleep 20 h** | | **1.13 kWh saved** | **~410 kWh saved** |

In that example, about **78 % of the idle energy** disappears. That is roughly €120 a year at
€0.30/kWh, and more if your box idles higher than ours. On a solar or battery-powered setup, 1.1 kWh
a day is a whole battery bank you do not need to charge just to keep a sleeping model warm.
(The "used" hours are counted at idle power for simplicity, because inference load costs the same
with or without this project.)

## What you get

| | Measured on our setup |
|---|---|
| Wall power: idle → suspended (Pi included) | **~60 W → ~3–4 W** |
| Wake-up after the magic packet (S3 resume) | ~9 s |
| Service reachable again, from the first request | ~14 s |
| VRAM preserved across sleep (2 × RTX 3060, 22 GB in use) | saved in ~16 s, model stays loaded |
| Pi Zero W ↔ PC throughput over Wi-Fi | ~4.3 MB/s (token streaming needs 10–20 KB/s) |
| `cloudflared` on the Pi Zero W | ~33 MB RAM, official `linux-arm` build works on ARMv6 |

Your numbers will differ. A cheap plug-in power meter tells you the two values that matter: idle
and suspended.

## Hardware it was built and tested on

- **PC:** NZXT N5 Z690 (ASRock-made BIOS), 2 × RTX 3060 12 GB, onboard Realtek RTL8125BG 2.5 GbE,
  Intel AX201 CNVi Wi-Fi, Ubuntu 26.04 LTS (kernel 7.0), NVIDIA driver 595
- **Always-on device:** Raspberry Pi Zero W Rev 1.1, Raspberry Pi OS Lite 13 (trixie), on Wi-Fi
- **LLM stack:** an OpenAI-compatible server on `127.0.0.1:8082` plus Open WebUI on `127.0.0.1:8080`.
  Anything that speaks HTTP works: llama.cpp `llama-server`, Ollama, vLLM, LM Studio and others.

## Repository layout

```
shared/tcpfwd.py              TCP forwarder: "wake" mode on the Pi, "lan" mode on the PC
pc/idle-watch.py              decides when the PC is unused and suspends it
pc/install.sh                 PC installer (WoL, firewall, services)
pc/test-wake.sh               end-to-end suspend → magic packet → resume test with timestamps
pi/install.sh                 Pi installer (wake-pc, wake proxy, cloudflared)
pi/wol.py, pi/wake-pc         magic packet sender
pi/cloudflared-config.example.yml
experiments/                  approaches that did NOT work for us, kept for reference
docs/GUIDE.md                 step-by-step setup
docs/LESSONS.md               everything we tried, what failed and why
```

## Quick start

1. Read [docs/GUIDE.md](docs/GUIDE.md). It starts with a 5-minute check that your PC can be woken
   at all.
2. Wire the PC to the router. **Wake-on-LAN over Wi-Fi did not survive S3 on our board.** If you
   want to know why, and what else we tried, see [docs/LESSONS.md](docs/LESSONS.md).
3. `sudo ./pi/install.sh` on the Pi and `sudo ./pc/install.sh` on the PC, then set up the tunnel.

## Key gotchas (the short version)

- **Suspend only through `systemctl suspend`.** With NVIDIA's `PreserveVideoMemoryAllocations=1`,
  `rtcwake -m mem` or writing to `/sys/power/state` skips `nvidia-suspend.service`, and the GPUs
  refuse to sleep (`nv_pmops_suspend returns -5`).
- **A root service cannot simply call `systemctl suspend` while you are logged in.** It is refused
  with "User X is logged in on tty2". Check the `block` inhibitors yourself, then use `systemctl suspend -i`.
- **Each suspend writes the VRAM contents to disk** (~22 GB here, ~16 s). On a 600 TBW NVMe, five
  suspends a day would need about 15 years to reach the rated endurance. You can also keep the dump
  in RAM for zero SSD wear: see [the SSD wear section of the guide](docs/GUIDE.md#does-saving-vram-wear-out-the-ssd).
- **Turn off your desktop's own automatic suspend.** GNOME only looks at keyboard and mouse, so it
  would put the PC to sleep in the middle of a remote generation.
- **Never suspend if the Pi is down.** Nobody could wake the PC again. `idle-watch` pings the Pi
  before every suspend.
- **Prove your wake tests with timestamps.** "It woke up" proved nothing at least four times in this
  project. See the lessons.

## License

MIT. See [LICENSE](LICENSE).
