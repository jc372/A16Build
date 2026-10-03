#!/usr/bin/env bash
# a16-display-probe.sh -- reproduce the display bring-up failure ON DEMAND and
# capture it, in a boot where msm is enabled (i.e. entry [3], the black-screen
# one).  Writes one log to the ESP so the run is readable afterwards.
#
#     sudo bash /home/jc/a16-payload/a16-display-probe.sh
#
# Type it blind if you have to: the screen is already dead in that boot, and the
# evidence lands in /boot/efi/A16DISPLAYPROBE-<stamp>.log.  Nothing here is
# destructive: it only unloads/reloads the display driver and re-binds the two
# USB3/DP combo PHYs, which re-runs exactly the init that failed at build time.
set -u

ESP="${A16_ESP:-/boot/efi}"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
if touch "$ESP/.a16p" 2>/dev/null; then rm -f "$ESP/.a16p"; LOG="$ESP/A16DISPLAYPROBE-$STAMP.log"; else LOG="/var/tmp/A16DISPLAYPROBE-$STAMP.log"; fi
: > "$LOG"
log()  { printf '[a16-probe] %s\n' "$*" | tee -a "$LOG"; }
run()  { local out st; out="$("$@" 2>&1)"; st=$?; { echo "### \$ $*"; printf '%s\n' "$out"; echo "### exit: $st"; } | tee -a "$LOG"; return $st; }
kcaps(){ echo "### $1" >>"$LOG"; bash -c "$2" 2>&1 | tee -a "$LOG"; }

if [ "$(id -u)" != "0" ]; then echo "[a16-probe] needs root: sudo bash $0"; exit 1; fi
log "=== a16-display-probe $STAMP  kernel $(uname -r) ==="
log "cmdline: $(cat /proc/cmdline)"
log "msm loaded: $(grep -c '^msm ' /proc/modules)   dp/phy modules: $(grep -cE '^(phy_qcom_qmp_combo|msm) ' /proc/modules)"

log "=== 1. state before ==="
kcaps "framebuffer / drm" 'cat /proc/fb 2>/dev/null; ls -l /sys/class/drm/ 2>/dev/null | head; grep -H . /sys/class/drm/*/status 2>/dev/null'
kcaps "PHY + DP runtime PM" 'for d in /sys/bus/platform/devices/*; do n=$(basename "$d"); case "$n" in *.phy|*display*) if [ -L "$d/driver" ]; then drv=$(basename "$(readlink -f "$d/driver")"); else drv="(no driver)"; fi; printf "%-34s driver=%-26s runtime_status=%-14s control=%s\n" "$n" "$drv" "$(cat "$d/power/runtime_status" 2>/dev/null)" "$(cat "$d/power/control" 2>/dev/null)";; esac; done 2>/dev/null'
kcaps "clocks: prim/sec/tert PHY" 'grep -iE "usb3_(prim|sec|tert)_phy|usb_[012]_phy" /sys/kernel/debug/clk/clk_summary 2>/dev/null'
kcaps "power domains" 'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | grep -iE "gdsc|usb|mdss|disp" | head -40; echo "(--- all domains ---)"; ls -1 /sys/kernel/debug/pm_genpd/ 2>/dev/null | head -60'
kcaps "log so far (display lines)" 'journalctl -k -b --no-pager 2>/dev/null | grep -iE "msm|dpu|dp_|panel|edp|com_aux|stuck|qmp_combo|phy_init|Failed to enable" | tail -40'

log "=== 2. re-run the failing init: reload msm ==="
run modprobe -r msm
sleep 2
run modprobe msm
sleep 8
kcaps "log after reload (display lines)" 'journalctl -k --no-pager -n 400 2>/dev/null | grep -iE "msm|dpu|dp_|panel|edp|com_aux|stuck|qmp_combo|phy_init|Failed to enable|fb0|Initialized msm|could not bind|probe.*failed" | tail -50'

log "=== 3. re-bind the two combo PHYs (tert is the HDMI/DP one) ==="
for dev in 88e1000.phy fde000.phy fd5000.phy; do
  [ -e "/sys/bus/platform/devices/$dev" ] || { log "$dev: not present in this boot"; continue; }
  drv="$(basename "$(readlink -f /sys/bus/platform/devices/$dev/driver 2>/dev/null)" 2>/dev/null)"
  log "$dev: driver=$drv  runtime=$(cat /sys/bus/platform/devices/$dev/power/runtime_status 2>/dev/null)"
  [ "$drv" = "phy-qcom-qmp-combo" ] || { log "  skipping (unexpected driver)"; continue; }
  run bash -c "echo '$dev' > /sys/bus/platform/drivers/phy-qcom-qmp-combo/unbind"
  sleep 1
  run bash -c "echo '$dev' > /sys/bus/platform/drivers/phy-qcom-qmp-combo/bind"
  sleep 3
  log "  $dev runtime now: $(cat /sys/bus/platform/devices/$dev/power/runtime_status 2>/dev/null)"
  kcaps "  log for $dev" "journalctl -k --no-pager -n 120 2>/dev/null | grep -iE '$dev|com_aux|stuck|Failed to enable' | tail -12"
done

log "=== 4. state after ==="
kcaps "clocks after" 'grep -iE "usb3_(prim|sec|tert)_phy" /sys/kernel/debug/clk/clk_summary 2>/dev/null'
kcaps "framebuffer after" 'cat /proc/fb 2>/dev/null; grep -H . /sys/class/drm/*/status 2>/dev/null'
kcaps "full log tail" 'journalctl -k -b --no-pager 2>/dev/null | tail -60'

log "=== done: log written to the ESP ==="
sync
OUT="/home/jc/a16-payload/$(basename "$LOG")"
if cp -f "$LOG" "$OUT" 2>/dev/null; then chown --reference=/home/jc/a16-payload "$OUT" 2>/dev/null; fi
echo "[a16-probe] log: $LOG   (copy: $OUT)"
exit 0
