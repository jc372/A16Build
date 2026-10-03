#!/usr/bin/env bash
# steps/20-dt-boot.sh -- confirm this boot is the device-tree one and that the internal input
#                        devices and the panel came up; re-stage the DT entries if they did not.
#
#   bash steps/20-dt-boot.sh
#
# Read-only unless the DT entries are missing, in which case it tells you to run the stager with
# sudo (it does not reboot the machine for you).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRINGUP="$(dirname "$HERE")"; TOOLS="$BRINGUP/tools"
LOG="${A16_LOG:-$HOME/a16-payload/A16STEP20-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== step 20: device-tree boot $(date +%Y%m%d-%H%M%S) ==="
CMDLINE="$(cat /proc/cmdline)"
say "   cmdline: $(printf '%s' "$CMDLINE" | cut -c1-120)…"

if ! printf '%s' "$CMDLINE" | tr ' ' '\n' | grep -qx 'acpi=off'; then
  say ""
  say "   This is NOT a device-tree boot (no acpi=off).  Internal keyboard/touchpad cannot work"
  say "   in ACPI mode on this platform: the firmware's I2C controllers are ACPI\\QCOM0F10, which"
  say "   i2c-qcom-geni does not match, so the I2C-HID children never enumerate."
  say ""
  say "   Reboot and take a DT entry -- on this machine:"
  say "     [1] 7.2 + glymur DTB, internal input, panel via firmware framebuffer"
  say "   then run this step again."
  say "log: $LOG"; exit 1
fi
say "   acpi=off: yes (device-tree boot)"

if [ -f "$TOOLS/a16-dt-verify.sh" ]; then
  say "   running tools/a16-dt-verify.sh …"
  bash "$TOOLS/a16-dt-verify.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
else
  say "   (tools/a16-dt-verify.sh not present -- skipping)"
fi

say ""
INPUT="$(grep -cE 'Name="(Asus Keyboard|hid-over-i2c 093A:3012 Touchpad)"' /proc/bus/input/devices 2>/dev/null || echo 0)"
if [ "${INPUT:-0}" -ge 2 ]; then
  say "   internal input: present (keyboard + touchpad)"
else
  say "   internal input: MISSING ($INPUT of 2) -- re-stage the DT entries with:"
  say "     sudo bash $TOOLS/a16-stage-dt-boot.sh"
  say "   and check $ESP/A16DTBOOT.LOG"
fi
say "   panel: $(ls /sys/class/drm/*/status 2>/dev/null | while read f; do printf '%s=%s ' "$(basename "$(dirname "$f")")" "$(cat "$f")"; done)"
say "   backlight: $(ls /sys/class/backlight/ 2>/dev/null || echo 'none (firmware-controlled)')"
say ""
say "   NEXT: sudo bash steps/30-firmware.sh"
say "log: $LOG"
