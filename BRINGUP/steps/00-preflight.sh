#!/usr/bin/env bash
# steps/00-preflight.sh -- read-only: is this machine, and is everything the later steps need,
#                          present?  Run this first; it changes nothing.
#
#   bash steps/00-preflight.sh
#
# Exits non-zero if a hard prerequisite is missing (so reproduce.sh stops here).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"        # BRINGUP/
PAYLOAD="${A16_PAYLOAD:-/home/jc/a16-payload}"
BUNDLE="$PAYLOAD/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst"
BUNDLE_SHA="2cb362c251fe31db687f22a2"           # prefix, from payload/sha256sums.txt
LOG="${A16_LOG:-$HOME/a16-payload/A16STEP00-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$HOME/a16-payload" ] || mkdir -p "$HOME/a16-payload" 2>/dev/null || LOG=/var/tmp/a16-step00.log
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
ok=0; bad=0
chk() {  # chk <required|info> <label> <command...>
  local need="$1" label="$2"; shift 2
  local out; out="$("$@" 2>&1 | head -1)"
  if [ -n "$out" ]; then say "   ok   $label: $out"; ok=$((ok+1))
  else
    if [ "$need" = required ]; then say "   FAIL $label (required)"; bad=$((bad+1))
    else say "   --   $label: (absent)"; fi
  fi
}

say "=== A16 preflight $(date +%Y%m%d-%H%M%S) ==="

say "machine"
MODEL="$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null)"
say "   model: ${MODEL:-unknown}"
case "$MODEL" in *UX3607OA*|*"Zenbook A16"*|*"Zenbook A16"*) : ;;
  *) say "   WARNING: this is not the Zenbook A16 these steps were written for -- do not continue"; bad=$((bad+1)) ;;
esac
chk info "kernel"        sh -c 'uname -r'
chk info "cmdline acpi"  sh -c 'tr " " "\n" < /proc/cmdline | grep -m1 "^acpi=off$"'
chk info "devicetree live" sh -c 'test -d /proc/device-tree/soc@0 && echo yes'
chk info "boot id"       sh -c 'cat /proc/sys/kernel/random/boot_id | cut -c1-8'

say "tools"
for t in sudo dtc zstd tar python3 sha256sum; do
  if command -v "$t" >/dev/null; then say "   ok   $t: $(command -v "$t")"; ok=$((ok+1))
  else
    case "$t" in python3|tar|sha256sum|sudo) say "   FAIL $t (required)"; bad=$((bad+1)) ;;
    *) say "   --   $t missing (needed from step 50: sudo apt install device-tree-compiler)";; esac
  fi
done

say "payload ($PAYLOAD)"
chk required "kernel bundle" sh -c "test -f '$BUNDLE' && stat -c '%s bytes  %n' '$BUNDLE'"
if [ -f "$BUNDLE" ]; then
  got="$(sha256sum "$BUNDLE" | cut -c1-24)"
  case "$got" in "$BUNDLE_SHA"*) say "   ok   bundle sha256 $got… (matches the payload manifest)"; ok=$((ok+1));;
    *) say "   FAIL bundle sha256 $got… -- expected $BUNDLE_SHA…"; bad=$((bad+1));; esac
fi
chk required "repo clone" sh -c "test -d '$HOME/A16Build/.git' && echo '$HOME/A16Build'"
chk info "repo branch" sh -c "HOME=/home/jc /home/jc/.local/bin/git -C '$HOME/A16Build' rev-parse --abbrev-ref HEAD 2>/dev/null"
chk info "firmware tree" sh -c "test -d '$HOME/A16Build/firmware/windows-driverstore-2026-09-16' && du -sh '$HOME/A16Build/firmware/windows-driverstore-2026-09-16' | cut -f1"
chk required "module space" sh -c "test \$(df -Pk /lib/modules | awk 'NR==2{print \$4}') -gt 800000 && echo 'ok (>800 MB free in /lib/modules)'"

say "current state (what is already done)"
chk info "DTB in use"      sh -c 'dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -qm1 "qcom,wcn7850-bt" && echo "patched (BT serdev client present)"'
chk info "bluetooth"       sh -c 'bluetoothctl list 2>/dev/null | grep -m1 Controller'
chk info "wifi iface"      sh -c 'ls /sys/class/net | grep -m1 "^wl"'
chk info "internal input"  sh -c 'grep -m1 "Asus Keyboard" /proc/bus/input/devices'
chk info "audio card"      sh -c 'aplay -l 2>/dev/null | grep -m1 "^card"'
chk info "battery"         sh -c 'upower -i /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat 2>/dev/null | awk "/state:|percentage:|time to/ {gsub(/^ +/,\"\"); printf \"%s  \", \$0}"'

say ""
if [ "$bad" -gt 0 ]; then
  say "PREFLIGHT: $bad missing prerequisite(s), $ok present.  Fix those, then re-run."
  say "log: $LOG"; exit 1
fi
say "PREFLIGHT: all prerequisites present ($ok checks)."
say "next: sudo bash steps/10-kernel.sh   (or: bash reproduce.sh --list)"
say "log: $LOG"
