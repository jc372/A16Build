#!/usr/bin/env bash
# a16-boot-report.sh -- write the state needed to explain a dark panel (and to
# check the internal input devices) into a report on the ESP, once per boot.
#
# Run by a16-boot-report.service (install with a16-enable-boot-report.sh), and
# safe to run by hand:  sudo bash /home/jc/a16-payload/a16-boot-report.sh
#
# Why: on the devicetree boot the machine comes up fine (simpledrm framebuffer,
# gdm, gnome-shell, all four internal i2c-HID devices) yet the panel stays dark,
# so the cause is a hardware state difference the kernel log does not spell out.
# This captures clocks / regulators / GPIO state on every boot so the DT boot can
# be diffed against the working ACPI boot instead of guessed at.
#
# Design rules (arm64-laptop-bringup): never fail the boot, no `set -e`, guard
# every step, and prefer the machine-readable sink.
set -u

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
BOOTID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8 || echo unknown)"
MODE=acpi
grep -q 'acpi=off' /proc/cmdline 2>/dev/null && MODE=devicetree
DIR=""
# Sink preference, most reliable first.  The ESP is last: it is FAT, the clock is unset early in
# the boot (so its mtimes are bogus), its FAT has silently dropped writes -- and it is the only
# sink that cannot be read if the machine is having a bad day.  The internal disk is ext4 and the
# operator can always read it.
USER_HOME="$(getent passwd "${SUDO_USER:-jc}" | cut -d: -f6)"
for cand in ${A16_REPORT_DIR:-$USER_HOME/a16-payload/a16-reports /var/log/a16-reports /boot/efi/a16-reports}; do
  if mkdir -p "$cand" 2>/dev/null && touch "$cand/.w" 2>/dev/null; then rm -f "$cand/.w"; DIR="$cand"; break; fi
done
[ -n "$DIR" ] || { echo "no writable report dir"; exit 0; }
R="$DIR/$STAMP-$MODE-$BOOTID"
mkdir -p "$R" 2>/dev/null || exit 0

cap() { local f="$1"; shift; { echo "### \$ $*"; "$@" 2>&1; echo "### exit: $?"; } > "$R/$f" 2>&1 || true; }
caps() { local f="$1"; shift; { echo "### \$ $*"; bash -c "$*" 2>&1; echo "### exit: $?"; } > "$R/$f" 2>&1 || true; }

# ---- identity -------------------------------------------------------------
{
  echo "mode: $MODE   (acpi=off present: $(grep -c 'acpi=off' /proc/cmdline 2>/dev/null))"
  echo "date: $(date 2>/dev/null)   uptime: $(uptime 2>/dev/null)"
  echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
  echo "kernel: $(uname -a 2>/dev/null)"
  echo "dt model: $(cat /sys/firmware/devicetree/base/model 2>/dev/null || echo '(none - ACPI boot)')"
  echo "acpi tables: $(ls /sys/firmware/acpi/tables 2>/dev/null | wc -l)"
} > "$R/00-identity.txt" 2>&1
caps 01-modules.txt 'lsmod'
cap 02-input-devices.txt cat /proc/bus/input/devices
caps 03-input-by-path.txt 'ls -l /dev/input/by-path; ls -l /dev/hidraw* 2>/dev/null'
caps 04-i2c.txt 'for a in /sys/class/i2c-adapter/*; do echo "$(basename $a): $(cat $a/name 2>/dev/null)"; done 2>/dev/null; echo "--- clients ---"; for d in /sys/bus/i2c/devices/*; do [ -e "$d" ] || continue; if [ -L "$d/driver" ]; then drv=$(basename $(readlink -f "$d/driver")); else drv="(no driver)"; fi; echo "$(basename $d) name=$(cat $d/name 2>/dev/null) driver=$drv"; done 2>/dev/null'
caps 05-display.txt 'echo "--- /proc/fb ---"; cat /proc/fb 2>/dev/null; echo "--- fb0 ---"; grep -H . /sys/class/graphics/fb0/name /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/stride /sys/class/graphics/fb0/state 2>/dev/null; echo "--- drm cards ---"; for c in /sys/class/drm/card*/; do echo "$(basename $c) driver=$(grep -h DRIVER $c/device/uevent 2>/dev/null)"; done; echo "--- connectors ---"; grep -H . /sys/class/drm/*/status 2>/dev/null; echo "--- /dev/dri ---"; ls -l /dev/dri 2>/dev/null; echo "--- backlight ---"; ls /sys/class/backlight 2>/dev/null || echo "(none)"; grep -H . /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness 2>/dev/null'
cap 06-gpio.txt cat /sys/kernel/debug/gpio
cap 07-regulator-summary.txt cat /sys/kernel/debug/regulator/regulator_summary
caps 08-clk-display.txt 'grep -iE "disp_cc|dispcc|edp|mdss|mdp|dptx|vsync|byte|pixel|video_cc|videocc|gpu_cc|gpucc" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -200'
caps 09-clk-critical.txt 'grep -iE "boot|critical|prepare_count" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -40'
cap 10-dmesg.txt dmesg
caps 11-dmesg-display-input.txt 'dmesg 2>/dev/null | grep -iE "drm|simpledrm|fb0|fbcon|msm|dpu|panel|edp|clk|regulator|gpio|pinctrl|tlmm|i2c|hid" | tail -400'
caps 12-klog.txt 'journalctl -k -b --no-pager 2>/dev/null | tail -300'
caps 13-sessions.txt 'loginctl list-sessions --no-pager; echo "--- gdm/gnome ---"; journalctl -b --no-pager 2>/dev/null | grep -iE "gnome-shell\[.*(card|primary|gbm|Wayland display server)|Gdm:|gdm.service" | tail -20'

# ---- power domains and runtime PM: where the display PHYs live -------------
# The tert USB3/DP combo PHY's clocks read "stuck at 'off'" while prim/sec are
# fine, and the DTS wiring matches upstream -- so the suspect is the PHY's power
# domain (GCC_USB_2_PHY_GDSC): a collapsed GDSC makes branch writes no-ops, which
# is exactly what "status stuck at 'off'" plus -EBUSY looks like.
caps 14-genpd.txt 'cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -120; echo "--- domains registered ---"; ls -1 /sys/kernel/debug/pm_genpd/ 2>/dev/null | head -60'
caps 15-runtime-pm.txt 'for d in /sys/bus/platform/devices/*; do n=$(basename "$d"); case "$n" in *.phy|*display*|*hdmi*|*remoteproc*|*pcie*) if [ -L "$d/driver" ]; then drv=$(basename "$(readlink -f "$d/driver")"); else drv="(no driver)"; fi; printf "%-34s driver=%-26s runtime_status=%-14s control=%s\n" "$n" "$drv" "$(cat "$d/power/runtime_status" 2>/dev/null)" "$(cat "$d/power/control" 2>/dev/null)";; esac; done 2>/dev/null'
caps 16-clk-phy.txt 'grep -iE "usb3_(prim|sec|tert|mp)_phy|usb_[012]_phy|gdsc" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -80'

# ---- auto-probe: OBSERVATIONAL ONLY, in a devicetree boot with msm enabled ---
# Entries [3]/[4] let parts of msm touch MDSS, which is exactly what kills the
# firmware picture.  The earlier version reloaded msm to re-run the init; on this
# hardware that can wedge the boot (no visible screen, no way to tell), so now we
# only *record*: the boot itself already ran the init and logged it.
if [ "$MODE" = "devicetree" ] && ! grep -q 'module_blacklist=msm' /proc/cmdline 2>/dev/null; then
  if [ ! -e /run/a16-autoprobe-done ]; then
    : > /run/a16-autoprobe-done 2>/dev/null
    echo "auto-probe (observational): devicetree boot with msm enabled" >> "$R/99-summary.txt" 2>/dev/null
    caps 17-autoprobe-state.txt 'echo "--- display devices and their drivers ---"; for d in /sys/bus/platform/devices/*; do n=$(basename "$d"); case "$n" in *.phy|*display*|*hdmi*) if [ -L "$d/driver" ]; then drv=$(basename "$(readlink -f "$d/driver")"); else drv="(no driver bound)"; fi; printf "%-34s driver=%-26s runtime=%s\n" "$n" "$drv" "$(cat "$d/power/runtime_status" 2>/dev/null)";; esac; done 2>/dev/null; echo "--- PHY clocks ---"; grep -iE "usb3_(prim|sec|tert)_phy" /sys/kernel/debug/clk/clk_summary 2>/dev/null; echo "--- relevant power domains ---"; grep -iE "gdsc|usb|mdss|disp" /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -40'
    caps 18-autoprobe-log.txt 'journalctl -k -b --no-pager 2>/dev/null | grep -iE "msm|mdss|dpu|dp_display|displayport|phy_init|com_init|Failed to enable|stuck|panel|edp|atna33|Initialized|fb0|could not bind|component|WARN|Oops|call trace" | tail -80'
    caps 19-autoprobe-drm.txt 'echo "--- framebuffer ---"; cat /proc/fb 2>/dev/null; echo "--- drm cards and drivers ---"; for c in /sys/class/drm/card*/; do echo "$(basename $c) driver=$(grep -h DRIVER $c/device/uevent 2>/dev/null)"; done; echo "--- connectors ---"; grep -H . /sys/class/drm/*/status 2>/dev/null; echo "--- /dev/dri ---"; ls -l /dev/dri 2>/dev/null; echo "--- gnome/gdm view ---"; loginctl list-sessions --no-pager'
  fi
fi

# ---- big dumps, compressed -------------------------------------------------
if command -v gzip >/dev/null 2>&1; then
  gzip -c /sys/kernel/debug/clk/clk_summary > "$R/20-clk_summary.txt.gz" 2>/dev/null
  dmesg 2>/dev/null | gzip -c > "$R/21-dmesg.txt.gz" 2>/dev/null
  journalctl -k -b --no-pager 2>/dev/null | gzip -c > "$R/22-klog.txt.gz" 2>/dev/null
  gzip -c /sys/kernel/debug/regulator/regulator_summary > "$R/23-regulator_summary.txt.gz" 2>/dev/null
fi

# ---- human-readable summary ------------------------------------------------
{
  echo "a16 boot report  $STAMP  mode=$MODE  boot=$BOOTID"
  echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
  echo "input devices:  $(grep -ac '^N: Name=' /proc/bus/input/devices 2>/dev/null)"
  echo "  internal i2c-hid: $(grep -ac 'hid-over-i2c' /proc/bus/input/devices 2>/dev/null)  (all names below)"
  grep -a '^N: Name=' /proc/bus/input/devices 2>/dev/null | sed 's/^/    /'
  echo "blacklist check (should be empty): $(grep -hoE '^(msm|dispcc_glymur|gpucc_glymur|videocc_glymur|phy_qcom_edp|panel_samsung_atna33xc20) ' /proc/modules 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
  echo "unknown kernel params: $(dmesg 2>/dev/null | grep -i 'unknown kernel command line' | tail -1)"
  echo "i2c adapters:   $(ls -d /sys/bus/i2c/devices/i2c-* 2>/dev/null | wc -l)  ($(ls -d /sys/bus/i2c/devices/i2c-* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' '))"
  echo "i2c clients:    $(ls -d /sys/bus/i2c/devices/* 2>/dev/null | wc -l)"
  echo "gpiochips:      $(ls -d /sys/class/gpio/gpiochip* 2>/dev/null | wc -l)"
  echo "drm cards:      $(ls -d /sys/class/drm/card* 2>/dev/null | tr '\n' ' ')"
  echo "framebuffer:    $(cat /proc/fb 2>/dev/null | tr '\n' ' ')"
  echo "panel rail VREG_EDP_3P3: $(grep -h 'VREG_EDP_3P3' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -2 || echo '(rail not registered - normal on ACPI)')"
  echo "regulator cleanups: $(dmesg 2>/dev/null | grep -c 'Not disabling unused regulators') skipped, $(dmesg 2>/dev/null | grep -c ': disabling') disabled"
  echo "display clocks (from 08-clk-display.txt): $(grep -c . "$R/08-clk-display.txt" 2>/dev/null) lines"
  echo "dmesg display/input lines: $(grep -c . "$R/11-dmesg-display-input.txt" 2>/dev/null)"
  echo "display PHY / DP runtime PM (from 15-runtime-pm.txt):"
  grep -aE 'phy|display' "$R/15-runtime-pm.txt" 2>/dev/null | grep -av '^###' | sed 's/^/    /' | head -20
  echo "power domains: $(grep -c . "$R/14-genpd.txt" 2>/dev/null) lines in 14-genpd.txt"
  echo "tert/prim/sec PHY clocks (from 16-clk-phy.txt):"
  grep -aE 'usb3_(prim|sec|tert)_phy' "$R/16-clk-phy.txt" 2>/dev/null | sed 's/^/    /' | head -12
  echo "files:"
  ls -la "$R" 2>/dev/null | sed 's/^/    /'
} > "$R/99-summary.txt" 2>&1

# keep the last 6 report sets only, so the sink never fills.
# Careful: this sorts by mtime, and on the ESP (FAT, with the clock unset early in the boot) the
# mtimes are unreliable -- the sort can therefore prune the wrong entries.  That is one more
# reason the internal disk is the default sink now.
ls -1dt "$DIR"/* 2>/dev/null | tail -n +7 | xargs -r rm -rf 2>/dev/null
sync

# Verify instead of asserting: the ESP's FAT has silently dropped these writes before (a run
# printed a path that the next boot could not find), so say whether the files are actually there.
if [ -s "$R/99-summary.txt" ] && [ "$(ls -1 "$R" 2>/dev/null | wc -l)" -gt 10 ]; then
  echo "a16 boot report: OK  $R/99-summary.txt  ($(ls -1 "$R" | wc -l) files, sink $DIR)"
else
  echo "a16 boot report: FAILED to write a complete set in $R (sink $DIR) -- see above for the reason"
fi
exit 0
