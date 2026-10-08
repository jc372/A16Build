#!/usr/bin/env bash
# bootcheck -- append one line per boot to ~/a16-payload/boot-health.log.
#
# Why: boot-to-boot variance on this machine is real -- the eDP link trains on some
# boots and not others with identical artifacts (same kernel, DTB file, initrd, menu
# default). This records what actually DIFFERS run to run, so the pattern shows up as
# data after ~15 boots instead of being argued from memory.
#
# USER SESSION ONLY -- never with sudo (it reads your session's journal and sysfs).
#
# Usage:  bootcheck          append this boot's line, print it
#         bootcheck --show   print the table collected so far
#
# Reading it: if lt-fail=2 lines correlate with one column (die-max high, a dock
# present, amps<4), that column is the lever. If they scatter across all columns,
# the margin itself is the problem and a retrain-on-failure is the fix.

set -u
LOG=${A16_BOOT_HEALTH_LOG:-$HOME/a16-payload/boot-health.log}
mkdir -p "$(dirname "$LOG")"

if [ "${1:-}" = "--show" ]; then
  if command -v column >/dev/null 2>&1; then column -t -s'|' "$LOG"; else cat "$LOG"; fi
  exit 0
fi

b=$(journalctl --list-boots 2>/dev/null | tail -1 | awk '{print $1}')
[ -n "${b:-}" ] || b=0

lt=$(journalctl -k -b "$b" --no-pager 2>/dev/null | grep -c 'link training.*failed')
cam=$(journalctl -k -b "$b" --no-pager 2>/dev/null | grep -ciE 'camss|qcom-cci|csi2-phy|csid')
pd=$(journalctl -b "$b" --no-pager 2>/dev/null | grep -c 'duplicate partner altmode')
fbcon=$(cat /sys/class/vtconsole/vtcon1/bind 2>/dev/null || echo '?')
vt=$(cat /sys/class/tty/tty0/active 2>/dev/null || echo '?')
amps=$(for f in /sys/bus/soundwire/devices/sdw*/status; do cat "$f" 2>/dev/null; done | grep -c 'ttach')
tz=$(for f in /sys/class/thermal/thermal_zone*/temp; do cat "$f" 2>/dev/null; done | sort -n | tail -1)
tz=$(( ${tz:-0} / 1000 ))
ac=$(cat /sys/class/power_supply/*/online 2>/dev/null | head -1)
bat=$(cat /sys/class/power_supply/*/capacity 2>/dev/null | head -1)
dtb=$(grep -m1 -oE 'set default="[^"]*"' /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null | cut -d'"' -f2)
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)

printf '%s | lt-fail=%s | cam-binds=%s | altmode-bug=%s | fbcon=%s | VT=%s | amps=%s/4 | die-max=%sC | AC=%s | batt=%s%% | up=%ss | menu-default=%s\n' \
  "$(date -Is)" "$lt" "$cam" "$pd" "$fbcon" "$vt" "$amps" "$tz" "${ac:-?}" "${bat:-?}" "${up:-?}" "${dtb:-?}" >> "$LOG"

tail -1 "$LOG"
