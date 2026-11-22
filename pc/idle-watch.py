#!/usr/bin/env python3
"""Suspend the PC to RAM (S3) after IDLE_MINUTES of inactivity. Runs as root (systemd service).

The PC counts as BUSY if at least one of these is true:
  - real traffic to/from the AI services through the Pi in the last 120 s (activity file of tcpfwd lan)
  - a GPU above 10 % utilisation (the GPU that drives the desktop: above 50 %, it idles at 8-17 %)
  - an established SSH connection (local or through a tunnel)
  - an active local graphical session that is not idle (logind IdleHint=no)
  - 1-minute load average above LOAD_MAX
It never suspends if the Pi (the device that sends the magic packet) does not answer a ping.
It honours `systemd-inhibit --what=sleep --mode=block <command>` locks.

Environment: IDLE_MINUTES (30), PI_ADDR (required), LOAD_MAX (3.0), DRY_RUN=1 (log only).
"""
import glob, os, subprocess, time

IDLE_MINUTES = int(os.environ.get("IDLE_MINUTES", "30"))
PI = os.environ.get("PI_ADDR", "192.168.1.20")
ACTIVITY_GLOB = "/run/user/*/wake-activity"
LOAD_MAX = float(os.environ.get("LOAD_MAX", "3.0"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"

def log(*a):
    print(*a, flush=True)

def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def reasons_busy():
    r = []
    now = time.time()
    for f in glob.glob(ACTIVITY_GLOB):
        try:
            age = now - os.path.getmtime(f)
            if age < 120:
                r.append("AI traffic %ds ago" % age)
        except OSError:
            pass
    # NVIDIA only; without nvidia-smi this check is simply skipped
    for line in run(["nvidia-smi", "--query-gpu=index,utilization.gpu,display_active",
                     "--format=csv,noheader,nounits"]).splitlines():
        try:
            idx, util, disp = [x.strip() for x in line.split(",")]
            if int(util) > (50 if disp == "Enabled" else 10):
                r.append("GPU%s %s%%" % (idx, util))
        except ValueError:
            pass
    ssh = [l for l in run(["ss", "-Htn", "state", "established", "( sport = :22 )"]).splitlines() if l.strip()]
    if ssh:
        r.append("%d SSH connections" % len(ssh))
    for row in run(["loginctl", "list-sessions", "--no-legend"]).split("\n"):
        sid = row.split()[0] if row.split() else ""
        if not sid:
            continue
        p = dict(l.split("=", 1) for l in run(["loginctl", "show-session", sid, "-p", "Type", "-p", "Active",
                                               "-p", "IdleHint"]).splitlines() if "=" in l)
        if p.get("Type") in ("x11", "wayland") and p.get("Active") == "yes" and p.get("IdleHint") == "no":
            r.append("graphical session %s active" % sid)
    load1 = os.getloadavg()[0]
    if load1 > LOAD_MAX:
        r.append("load %.1f" % load1)
    return r

def pi_alive():
    return subprocess.run(["ping", "-c", "2", "-W", "2", PI], capture_output=True).returncode == 0

def sleep_blockers():
    return [l for l in run(["systemd-inhibit", "--list", "--no-pager", "--no-legend"]).splitlines()
            if "sleep" in l and l.rstrip().endswith("block")]

def main():
    log("idle-watch: suspend after %d min of inactivity%s" % (IDLE_MINUTES, " (DRY_RUN)" if DRY_RUN else ""))
    idle = 0
    first = True
    while True:
        busy = reasons_busy()
        if busy:
            if idle >= 5 or first:
                log("busy: " + ", ".join(busy))
            idle = 0
            first = False
        else:
            idle += 1
            if idle in (1, 10, 20, IDLE_MINUTES - 5):
                log("idle for %d min" % idle)
        if idle >= IDLE_MINUTES:
            blocks = sleep_blockers()
            if not pi_alive():
                log("Pi %s does not answer: NOT suspending (nobody could wake me up)" % PI)
                idle = IDLE_MINUTES - 5
            elif blocks:
                log("suspend blocked by systemd-inhibit: " + " | ".join(" ".join(b.split()[:5]) for b in blocks))
                idle = IDLE_MINUTES - 5
            elif DRY_RUN:
                log("DRY_RUN: I would suspend now")
                idle = 0
            else:
                log("idle for %d min -> systemctl suspend" % idle)
                # -i: root is otherwise refused while a user session is logged in ("User X is logged in
                # on tty2"). 'delay' inhibitors (screen lock, NetworkManager...) are still honoured.
                # Always go through systemctl: it runs nvidia-suspend.service, which saves VRAM.
                res = subprocess.run(["systemctl", "suspend", "-i"], capture_output=True, text=True)
                if res.returncode != 0:
                    log("suspend refused: " + (res.stderr.strip() or str(res.returncode)))
                    idle = IDLE_MINUTES - 5
                else:
                    time.sleep(90)   # wait for the suspend/resume cycle
                    log("resumed from suspend")
                    idle = 0
        time.sleep(60)

if __name__ == "__main__":
    main()
