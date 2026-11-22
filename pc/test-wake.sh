#!/bin/bash
# End-to-end Wake-on-LAN test. Run on the PC:  sudo PI=pi@192.168.1.20 ./pc/test-wake.sh
#  1. asks the Pi (over SSH, key auth) to run wake-pc in DELAY seconds
#  2. suspends the PC THROUGH SYSTEMD (needed for nvidia-suspend / VRAM preservation)
#  3. an RTC alarm wakes the PC after 600 s anyway, so a failed test never leaves it asleep
#  4. compares the Pi's timestamp with the kernel's resume time: only a resume within 30 s of
#     the magic packet counts as a success (a plain "it woke up" proves nothing: we had false positives)
# MODE=s2idle tests the shallower sleep state instead of S3 ("deep").
PI="${PI:-pi@192.168.1.20}"
DELAY="${DELAY:-90}"
U="${SUDO_USER:-$USER}"
LOG=/tmp/wake-test.log

as_user() { sudo -u "$U" "$@"; }
# two separate ssh calls: a single command line containing 'sleep 90' would make pkill kill itself
as_user ssh -o BatchMode=yes "$PI" "pkill -f 'slee[p] $DELAY'"
as_user ssh -o BatchMode=yes "$PI" "nohup sh -c 'sleep $DELAY; /usr/local/bin/wake-pc' >/tmp/wake-pc.log 2>&1 &"

T0=$(date +%s); echo "test start $(date)" | tee $LOG
[ -n "${MODE:-}" ] && echo "$MODE" > /sys/power/mem_sleep
echo "mem_sleep: $(cat /sys/power/mem_sleep)" | tee -a $LOG
rtcwake -m no -s 600 >/dev/null          # safety alarm only, does NOT suspend
systemctl suspend
for i in $(seq 900); do                  # wait for the whole suspend/resume cycle
  journalctl -k --since "@$T0" -q | grep -q "PM: suspend exit" && break
  sleep 1
done
K=$(journalctl -k --since "@$T0" -q -o short-unix)
E=$(echo "$K" | grep "PM: suspend entry" | head -1 | cut -d' ' -f1 | cut -d. -f1)
X=$(echo "$K" | grep "PM: suspend exit"  | head -1 | cut -d' ' -f1 | cut -d. -f1)
echo "$K" | grep -iE "PM: suspend|failed|wowlan" | tee -a $LOG
W=$(as_user ssh -o BatchMode=yes "$PI" "grep -o 'wake-pc at [0-9]*' /tmp/wake-pc.log" | awk '{print $3}')
echo "Pi wake-pc: ${W:-never ran}  resume: $X" | tee -a $LOG
echo "wakeup irq: $(cat /sys/power/pm_wakeup_irq 2>/dev/null)" | tee -a $LOG
if echo "$K" | grep -q "failed to suspend"; then echo "==> SUSPEND FAILED (see log above)" | tee -a $LOG
elif [ -z "$E" ] || [ -z "$X" ]; then echo "==> no suspend cycle found" | tee -a $LOG
else
  echo "slept $((X-E)) s" | tee -a $LOG
  if [ -n "$W" ] && [ $((X-W)) -ge 0 ] && [ $((X-W)) -le 30 ]; then echo "==> WOKEN BY THE PI ($((X-W)) s after the magic packet)" | tee -a $LOG
  elif [ $((X-E)) -ge 300 ]; then echo "==> woken by the RTC safety alarm: Wake-on-LAN did NOT work" | tee -a $LOG
  else echo "==> woke up too early: some other wake source" | tee -a $LOG; fi
fi
[ -n "${MODE:-}" ] && echo deep > /sys/power/mem_sleep
