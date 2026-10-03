#!/usr/bin/env bash
# a16-edp-debug.sh -- make the internal panel try to light up again, with the kernel narrating.
#
#   sudo bash a16-edp-debug.sh          # capture a fresh link-training attempt + all state
#   bash a16-edp-debug.sh --help
#
# Where this sits in the story: msm now binds (the GPUCC module was the missing piece), the panel
# shows up as card1-eDP-1 "connected" with two 2880x1800 modes, and a dp_aux_backlight device
# exists.  What still fails is the eDP *link*: at the first atomic enable the kernel reported
#
#   msm_dp_ctrl_link_train_1_2: *ERROR* link training #2 on phy 0 failed. ret=-110
#   msm_dp_ctrl_setup_main_link: *ERROR* link training on sink failed. ret=-110
#   msm_dp_aux_isr: *ERROR* Unexpected DP AUX IRQ 0x01000000 when not busy
#   msm_dp_display_atomic_enable: *ERROR* Failed link training (rc=-104)
#
# -110 is a timeout on the AUX/training exchange, and those messages names no cause.  This script
# turns on DRM's own debug output (driver + KMS + atomic), asks the connector to re-detect, forces
# the CRTC off and back on (which re-runs link training), and captures everything the kernel says
# about it -- plus the regulator, clock, GPIO and pinctrl state of the panel path in the same
# moment.  It is read-mostly: the only writes are DRM's debug level, the connector's status probe
# and dpms, all of which are normal kernel interfaces.  Safe to re-run; each run gets its own
# directory.
set -u

KVER="$(uname -r)"
OUT="/home/jc/a16-payload/edp-debug-$(date +%Y%m%d-%H%M%S)"
DRMDEBUG=/sys/module/drm/parameters/debug
CONN=/sys/class/drm/card1-eDP-1

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,10p' "$0"; exit 0
fi

[ "$(id -u)" = 0 ] || { echo "needs root: sudo bash $0"; exit 1; }
mkdir -p "$OUT" || exit 1
say() { printf '%s\n' "$*" | tee -a "$OUT/00-run.txt"; }

say "=== a16-edp-debug $(date +%Y%m%d-%H%M%S) ==="
say "kernel : $KVER   boot: $(cut -c1-8 /proc/sys/kernel/random/boot_id)"
say "output : $OUT"
say ""

say "== state before we poke it =="
{
  echo "cmdline: $(cat /proc/cmdline)"
  echo "uname  : $(uname -a)"
} > "$OUT/01-identity.txt"

for f in status enabled modes dpms; do
  [ -e "$CONN/$f" ] && printf '%-8s %s\n' "$f" "$(cat "$CONN/$f" 2>/dev/null | tr '\n' ' ')" >> "$OUT/02-connector.txt"
done
for c in /sys/class/drm/card1-*/; do
  printf '%-24s status=%-12s enabled=%-8s modes=%s\n' "$(basename "$c")" \
    "$(cat "$c/status" 2>/dev/null)" "$(cat "$c/enabled" 2>/dev/null)" "$(cat "$c/modes" 2>/dev/null | tr '\n' ' ')" >> "$OUT/02-connector.txt"
done
ls /sys/class/backlight/ >> "$OUT/02-connector.txt" 2>/dev/null
for b in /sys/class/backlight/*/; do for f in brightness actual_brightness max_brightness type bl_power; do printf '%s/%s = %s\n' "$(basename "$b")" "$f" "$(cat "$b/$f" 2>/dev/null)" >> "$OUT/02-connector.txt"; done; done

lsmod | grep -E 'msm|panel_samsung|phy_qcom_edp|dispcc|gpucc|gxclkctl|drm' > "$OUT/03-modules.txt"
cat /proc/fb >> "$OUT/03-modules.txt"
[ -r /sys/kernel/debug/regulator/regulator_summary ] && \
  cat /sys/kernel/debug/regulator/regulator_summary > "$OUT/04-regulators.txt"
grep -iE 'edp|vreg|panel' "$OUT/04-regulators.txt" >> "$OUT/04-regulators.txt" 2>/dev/null
[ -r /sys/kernel/debug/clk/clk_summary ] && {
  cp -f /sys/kernel/debug/clk/clk_summary "$OUT/05-clk-summary.txt"
  grep -iE 'edp|^ *dp|aux|pixel|link|mdp' "$OUT/05-clk-summary.txt" > "$OUT/05-clk-edp.txt"
}
[ -r /sys/kernel/debug/gpio ] && cp -f /sys/kernel/debug/gpio "$OUT/06-gpio.txt"
cat /sys/kernel/debug/devices_deferred > "$OUT/07-deferred.txt" 2>/dev/null
journalctl -k -b 0 --no-pager > "$OUT/08-dmesg-boot.txt" 2>/dev/null
grep -iE 'edp|panel|atna33|aux|faac00|link train|backlight|hpd' "$OUT/08-dmesg-boot.txt" \
  | grep -v 'Modules linked' > "$OUT/09-dmesg-display.txt" 2>/dev/null
say "   connector state, backlight, regulators, clocks, gpio, deferred probes captured"

say ""
say "== poke: DRM debug on, re-detect, CRTC off/on =="
OLD="$(cat "$DRMDEBUG" 2>/dev/null || echo 0)"
say "   drm.debug: $OLD -> 0x1e"
echo 0x1e > "$DRMDEBUG" 2>/dev/null || say "   (could not write $DRMDEBUG)"
MARK="$(date '+%Y-%m-%d %H:%M:%S')"
say "   forcing connector re-detect: echo detect > $CONN/status"
echo detect > "$CONN/status" 2>/dev/null || say "   (status probe not writable)"
sleep 2
say "   forcing a fresh modeset: dpms off, wait, dpms on"
echo off > "$CONN/dpms" 2>/dev/null || say "   (dpms not writable)"
sleep 2
echo on > "$CONN/dpms" 2>/dev/null
say "   waiting 8 s for link training to finish or fail…"
sleep 8
echo "$OLD" > "$DRMDEBUG" 2>/dev/null
say "   drm.debug restored to $OLD"

say ""
say "== what the kernel said during that attempt =="
journalctl -k -b 0 --since "$MARK" --no-pager > "$OUT/20-attempt-kernel.txt" 2>/dev/null
grep -iE 'link train|link_train|aux|dpcd|lane|hbr|panel|edp|backlight|failed|error' \
  "$OUT/20-attempt-kernel.txt" | grep -v 'Modules linked' > "$OUT/21-attempt-display.txt" 2>/dev/null
for f in status enabled modes; do printf '%-8s %s\n' "$f" "$(cat "$CONN/$f" 2>/dev/null | tr '\n' ' ')" >> "$OUT/22-connector-after.txt"; done

{
  echo "== the lines that matter (pre-grepped) =="
  echo "-- link training / aux, this attempt:"
  grep -hE 'link train|setup_main_link|aux_isr|atomic_enable' "$OUT/21-attempt-display.txt" 2>/dev/null | tail -20
  echo "-- panel / edp, this boot:"
  grep -hE 'atna33|panel|edp-phy|faac00' "$OUT/09-dmesg-display.txt" 2>/dev/null | tail -15
  echo "-- connector before -> after:"
  cat "$OUT/02-connector.txt" 2>/dev/null | head -6
  cat "$OUT/22-connector-after.txt" 2>/dev/null
} > "$OUT/30-summary.txt" 2>/dev/null

say "   files in $OUT:"
ls -1 "$OUT" | sed 's/^/     /'
say ""
say "START HERE: $OUT/30-summary.txt  (then 21-attempt-display.txt, 04-regulators.txt, 05-clk-edp.txt)"
say "Note: the WARN in this boot's log about 'gcc_usb3_tert_phy_com_aux_clk status stuck at off'"
say "comes from phy_qcom_qmp_combo -- the USB-C DP path, not the internal panel.  Separate item."
chown -R "${SUDO_USER:-jc}:${SUDO_USER:-jc}" "$OUT" 2>/dev/null
chmod -R a+rX "$OUT" 2>/dev/null
