#!/usr/bin/env python3
"""Tiny TCP forwarder with two modes (Python stdlib only, runs fine on a Pi Zero W).

PC  (mode "lan"):  listens on the PC's LAN address, accepts ONLY the Pi, forwards to services that
                   stay bound to 127.0.0.1, and records the last real activity in a file that
                   idle-watch reads to decide when the PC is unused.
Pi  (mode "wake"): listens on 127.0.0.1 (cloudflared connects here). If the PC does not answer it
                   runs WAKE_CMD (sends a Wake-on-LAN magic packet) and keeps retrying for up to
                   WAKE_TIMEOUT seconds, then forwards the connection.

It works at TCP level, so HTTP, SSE token streaming and WebSockets all pass through untouched.

Examples:
  tcpfwd.py lan  --listen 192.168.1.10 --allow 192.168.1.20 --map 18080:127.0.0.1:8080 --map 18082:127.0.0.1:8082
  tcpfwd.py wake --listen 127.0.0.1 --map 18080:192.168.1.10:18080 --map 18082:192.168.1.10:18082

Environment:
  ACTIVITY_FILE   (lan)  default /run/user/<uid>/wake-activity
  WAKE_CMD        (wake) default /usr/local/bin/wake-pc
  WAKE_TIMEOUT    (wake) default 120 seconds
"""
import argparse, asyncio, os, shlex, sys, time

ACTIVITY_FILE = os.environ.get("ACTIVITY_FILE", "/run/user/%d/wake-activity" % os.getuid())
ACTIVITY_MIN_BYTES = 512        # tiny packets (WebSocket pings) do not count as activity
WAKE_TIMEOUT = int(os.environ.get("WAKE_TIMEOUT", "120"))
WAKE_CMD = shlex.split(os.environ.get("WAKE_CMD", "/usr/local/bin/wake-pc"))

def log(*a):
    print(time.strftime("%F %T"), *a, flush=True)

_last_touch = 0.0
def touch_activity():
    global _last_touch
    now = time.time()
    if now - _last_touch < 5:
        return
    _last_touch = now
    try:
        with open(ACTIVITY_FILE, "w") as f:
            f.write("%d\n" % now)
    except OSError as e:
        log("activity file:", e)

async def pipe(reader, writer, track):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            if track and len(data) >= ACTIVITY_MIN_BYTES:
                touch_activity()
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass

_wake_lock = asyncio.Lock()
_last_wake = 0.0

async def open_upstream(host, port, wake):
    global _last_wake
    deadline = time.monotonic() + (WAKE_TIMEOUT if wake else 5)
    while True:
        try:
            return await asyncio.wait_for(asyncio.open_connection(host, port), timeout=2)
        except (OSError, asyncio.TimeoutError):
            if not wake or time.monotonic() > deadline:
                raise
        async with _wake_lock:
            # many parallel connections (a web UI opens several) -> one magic packet every 20 s max
            if time.monotonic() - _last_wake > 20:
                _last_wake = time.monotonic()
                log("PC not reachable on %s:%d -> sending magic packet" % (host, port))
                await asyncio.create_subprocess_exec(*WAKE_CMD, stdout=asyncio.subprocess.DEVNULL)
        await asyncio.sleep(2)

def make_handler(mode, uhost, uport, allow):
    async def handle(creader, cwriter):
        peer = cwriter.get_extra_info("peername")
        if allow and peer[0] not in allow:
            log("rejected", peer)
            cwriter.close()
            return
        try:
            t0 = time.monotonic()
            ureader, uwriter = await open_upstream(uhost, uport, mode == "wake")
            if time.monotonic() - t0 > 3:
                log("PC ready after %.0fs" % (time.monotonic() - t0))
        except Exception as e:
            log("upstream %s:%d unavailable: %s" % (uhost, uport, e))
            cwriter.close()
            return
        track = mode == "lan"
        if track:
            touch_activity()
        await asyncio.gather(pipe(creader, uwriter, track), pipe(ureader, cwriter, track))
    return handle

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["lan", "wake"])
    ap.add_argument("--listen", required=True)
    ap.add_argument("--allow", action="append", default=[], help="client IP allowed (repeatable)")
    ap.add_argument("--map", action="append", required=True, help="lport:host:port (repeatable)")
    a = ap.parse_args()
    servers = []
    for m in a.map:
        lport, host, port = m.split(":")
        srv = await asyncio.start_server(make_handler(a.mode, host, int(port), set(a.allow)),
                                         a.listen, int(lport), reuse_address=True)
        servers.append(srv)
        log("%s: %s:%s -> %s:%s" % (a.mode, a.listen, lport, host, port))
    await asyncio.gather(*(s.serve_forever() for s in servers))

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
