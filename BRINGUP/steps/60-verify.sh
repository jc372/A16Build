#!/usr/bin/env bash
# steps/60-verify.sh -- the acceptance checks for this bring-up.  Read-only, no root needed.
#
#   bash steps/60-verify.sh
#
# Required checks must pass (exit non-zero otherwise).  Info checks are the things this bring-up
# records but does not yet fix -- they are printed, not judged.
set -u
LOG="${A16_LOG:-$HOME/a16-payload/A16VERIFY-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass=0; fail=0

req() {  # req <label> <cmd…>   -> first line of output is the evidence
  local label="$1"; shift
  local out; out="$("$@" 2>&1 | head -1)"
  if [ -n "$out" ]; then say "   PASS  $label: $out"; pass=$((pass+1));
  else say "   FAIL  $label"; fail=$((fail+1)); fi
}
info() {
  local label="$1"; shift
  local out; out="$("$@" 2>&1 | head -1)"
  say "   ----  $label: ${out:-(absent)}"
}

say "=== A16 bring-up verification $(date +%Y%m%d-%H%M%S) ==="
say "   boot: $(uptime -s)   kernel: $(uname -r)"
say "   cmdline: $(tr ' ' '\n' < /proc/cmdline | grep -x 'acpi=off' >/dev/null && echo 'device-tree (acpi=off)' || echo ACPI)"

say ""
say "device tree + Bluetooth"
req "serdev client in the live DT" sh -c 'dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -qm1 "qcom,wcn7850-bt" && echo "compatible qcom,wcn7850-bt present"'
req "uart14 still enabled" sh -c 'test "$(tr -d "\0" < /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/status)" = okay && echo okay'
req "stub rails 6 of 6" sh -c 'n=$(ls -d /proc/device-tree/regulator-bt-* 2>/dev/null | wc -l); [ "$n" = 6 ] && echo "6 of 6"'
# this kernel exposes no name/address/hci_version attributes on hci0 (only power, reset, rfkill0),
# so the verdict is the driver's own version line plus bluetoothctl over D-Bus -- both readable by
# a plain user, which is what lets this script run without root
req "chip answered (QCA version line)" sh -c 'journalctl -k -b 0 --no-pager 2>/dev/null | grep -m1 "QCA controller version" | sed "s/^.*Bluetooth: //"'
req "controller registered and powered" sh -c 'bluetoothctl show 2>/dev/null | grep -m1 "Powered: yes"'
info "controller" sh -c 'bluetoothctl list 2>/dev/null | grep -m1 Controller'
info "rfkill" sh -c 'rfkill list bluetooth 2>/dev/null | tr "\n" " " | sed "s/  */ /g"'
info "rampatch download" sh -c 'journalctl -k -b 0 --no-pager 2>/dev/null | grep -m1 -E "QCA (Downloading|Failed to request)" | sed "s/^.*Bluetooth: //"'

say ""
say "Wi-Fi"
req "wlan interface up" sh -c 'd=$(ls -d /sys/class/net/wl* 2>/dev/null | head -1) && [ "$(cat $d/operstate)" = up ] && echo "$(basename $d) up"'
req "associated" sh -c 'iw dev wlP4p1s0 link 2>/dev/null | grep -m1 SSID'
info "signal / board-data failures" sh -c 'printf "signal=%s  board-data-failures=%s" "$(iw dev wlP4p1s0 link 2>/dev/null | grep -m1 signal | tr -d "\t")" "$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c "failed to fetch board data")"'

say ""
say "input + display"
req "internal keyboard" sh -c 'grep -m1 "Asus Keyboard" /proc/bus/input/devices'
req "internal touchpad" sh -c 'grep -m1 "hid-over-i2c 093A:3012 Touchpad" /proc/bus/input/devices'
info "panel connector" sh -c 'ls /sys/class/drm/*/status 2>/dev/null | while read f; do printf "%s=%s " "$(basename $(dirname $f))" "$(cat $f)"; done'
info "backlight" sh -c 'ls /sys/class/backlight/ 2>/dev/null | tr "\n" " "'
info "DRM driver" sh -c 'basename "$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null'

say ""
say "audio (known open -- see NEXT-STEPS.md item 3)"
info "sound card" sh -c 'aplay -l 2>/dev/null | grep -m1 "^card"'
info "DSPs" sh -c 'for r in /sys/class/remoteproc/remoteproc*/; do printf "%s=%s " "$(basename $r)" "$(cat $r/state 2>/dev/null)"; done'
info "default sink" sh -c 'wpctl status 2>/dev/null | grep -m1 "\*" | sed "s/^[^0-9]*//"'

say ""
say "power (item 4: confirm the gauge/charge-control -- the gauge itself works; item 5: suspend, untested)"
info "battery (upower)" sh -c 'upower -i /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat 2>/dev/null | awk "/state:|percentage:|capacity:|energy-full:|time to/ {gsub(/^ +/,\"\"); printf \"%s  \", \$0}"'
info "charge control (conservation mode)" sh -c 'b=/sys/class/power_supply/qcom-battmgr-bat; printf "%s/%s %%(start/end)  -- driver X1E80100 set exports no capacity attribute; upower derives the percentage from energy_*" "$(cat $b/charge_control_start_threshold 2>/dev/null)" "$(cat $b/charge_control_end_threshold 2>/dev/null)"'
info "mem_sleep" sh -c 'cat /sys/power/mem_sleep'

say ""
if [ "$fail" = 0 ]; then
  say "VERIFY: all $pass required checks passed."
else
  say "VERIFY: $fail of $((pass+fail)) required checks FAILED."
fi
say "log: $LOG"
[ "$fail" = 0 ]
