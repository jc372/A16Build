#!/usr/bin/env bash
# a16-wifi-sleep.sh -- make "close the lid, come back, Wi-Fi still there" work.
#
#   wifisleep                        status: what is set now, and which experiment to run next
#   sudo wifisleep test [n]          suspend n times (default 1) and say, after each resume,
#                                    whether the radio survived
#   sudo wifisleep s2idle on|off     use s2idle instead of deep for this boot (on: persist at boot)
#   sudo wifisleep hook test|on|off  the reload-across-suspend hook: prove it, install it, remove it
#   sudo wifisleep xhci [persist]    land the staged xhci suspend fix (it has never been loaded)
#   sudo wifisleep forensics         after a wedge: is the device still on the bus, and can it be
#                                    recovered without a reboot (A16_I_KNOW=1 for the driver rungs)
#
# WHY the radio dies, in one paragraph (evidence: BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt):
# the chip is a QCC2072 (17cb:1112), and ath12k says this chip family supports suspend
# (ath12k_hw_params ... .supports_suspend = true, drivers/net/wireless/ath/ath12k/wifi7/hw.c).
# The first suspend of a boot therefore tears the device down -- suspend_late -> ath12k_hif_power_down
# -> ath12k_mhi_stop(keep_dev) -- and the resume re-inits it: resume_early -> hif_power_up ->
# ath12k_mhi_start, then ath12k_core_resume() waits up to 20 s (ATH12K_RESET_TIMEOUT_HZ) for
# ab->restart_completed, which only ath12k_core_restart() completes (core.c:1680, the firmware-crash
# recovery path).  That completion never comes:
#
#     ath12k_wifi7_pci 0004:01:00.0: timeout while waiting for restart complete
#     ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110
#
# and the MHI lines immediately before those (boot -1, 2026-09-17 15:49:16) say what the device did:
#
#     mhi mhi0: Requested to power ON
#     mhi mhi0: Power on setup success
#     mhi mhi0: Wait for device to enter SBL or Mission mode     <- and that is the last MHI line
#
# i.e. after a deep suspend the chip is no longer running its firmware.  The resume path resets it
# (ath12k_pci_power_up -> ath12k_pci_sw_reset) and asks MHI to power it up, but the host-side firmware
# download lives in the probe/QMI flow and is not run here, so the device sits waiting to be booted
# until the 20 s timeout expires.  That is why the radio is dead for the rest of the boot, why a
# reboot (a fresh probe) brings it back, and why the reload hook is a candidate *fix* rather than a
# workaround: it runs the probe the resume path skips.
#
# and from then on every WMI command times out, so the interface cannot be brought up.  Nothing in
# userspace recovers it (NetworkManager/wpa_supplicant do nothing, unbind/bind leaves no netdev, the
# module unload froze the machine) -- which is why this script does not try to heal the wedge: it
# changes what the suspend does in the first place, and measures the result.
#
# The two ladders, cheapest first:
#   A. s2idle: the same driver callbacks, but no platform power collapse.  If the radio survives it,
#      the fault is the platform's deep-suspend power to the PCIe link/endpoint, not the driver's
#      MHI sequence -- and `s2idle on` is the whole fix (one line, no build).
#   B. the sleep hook: unload ath12k before the suspend, re-probe the device after it.  This is what
#      a boot does, so it is the strongest candidate if A fails; `hook test` proves the teardown is
#      safe on a healthy radio first (on a wedged radio it is what froze the machine on 2026-09-17).
# C. the upstream answer to the same question is "nothing": at linux-next master on 2026-09-22,
#    ath12k/core.c, mhi.c and wow.c are byte-identical to the tree this kernel was built from, and
#    there is no ath12k suspend/resume patch in flight (patchwork, q=ath12k suspend: latest 2024).
#    So no released or posted fix can be brought in for this path; the levers are A, B, and the
#    driver change (skip ath12k's own suspend/resume, as patches/0010 does for xhci).
set -u

MODE="${1:-status}"
ARG="${2:-}"
N="${2:-1}"
KVER=$(uname -r)
LOG="${A16_LOG:-/home/jc/a16-payload/wifi-sleep-$(date +%Y%m%d-%H%M%S).log}"
SKIP_ROOT="${A16_SKIP_ROOT:-0}"
DRY="${A16_DRY:-0}"
UPD="/lib/modules/$KVER/updates/a16"
INITRD="/boot/initrd.img-$KVER"
HOOK="/usr/lib/systemd/system-sleep/a16-wifi-reload"
TMPFILES="/etc/tmpfiles.d/a16-mem-sleep.conf"
GATE="${A16_I_KNOW:-0}"
BDF="0004:01:00.0"

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
# run a command unless A16_DRY=1 (used to exercise every mode without root)
run() {
  if [ "$DRY" = 1 ]; then say "   [dry-run] $*"; return 0; fi
  "$@"
}

usage() {
  cat <<'EOF'
wifisleep -- make a suspend stop costing the radio.

usage:
  wifisleep                     read-only: sleep mode, hook, the xhci fix's real state, radio state,
                                and the next command to type
  sudo wifisleep test [n]       suspend n times (default 1) and report after each resume whether the
                                radio survived (association, not routing).  Wake it with lid/key/power.
  sudo wifisleep s2idle on|off  on: mem_sleep=s2idle now, and persist it for every boot
                                off: back to deep (the default)
  sudo wifisleep hook test|on   *** CRASHED THE MACHINE on 2026-09-22 *** -- unloading ath12k hangs
                                it (a healthy radio, not just a wedged one).  A16_I_KNOW=1 to force.
  sudo wifisleep xhci           swap the patched xhci-plat-hcd.ko in for this boot.  *** This also
                                crashed the machine on 2026-09-22 (the next resume left a black screen
                                and no keyboard backlight) *** -- prefer `xhci persist`.  Forcing it
                                needs A16_I_KNOW=1.
  sudo wifisleep xhci persist   rebuild the initramfs so the patched module is the one that loads
  sudo wifisleep forensics      after a wedge: bus/PowerState/PCI lines, then recovery without reboot
                                (driver rungs need A16_I_KNOW=1)

measured, in order of what is left to try:
  1. test                 baseline.  deep: the radio dies (2026-09-17).  s2idle: the radio dies too
                          (2026-09-22) -- so it is ath12k's own resume path, not platform power.
  2. radiofix             the driver patch: do not SoC-global-reset the device on resume, so MHI can
                          re-attach to the firmware the suspend deliberately kept.  ~/a16.sh radiofix
  3. forensics            on a wedge: is the device still on the bus, and does a PCI reset + rebind
                          recover it without a restart
  4. xhci persist         the second-suspend abort (rebuilds the initramfs; never swap the module)
the hook is out: unloading ath12k hangs this machine (twice measured).

log: ~/a16-payload/wifi-sleep-<timestamp>.log
env: A16_LOG, A16_SKIP_ROOT=1, A16_DRY=1 (print commands, change nothing), A16_I_KNOW=1
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

wifi_dev()  { nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'; }
mem_sleep() { tr ' ' '\n' < /sys/power/mem_sleep 2>/dev/null | tr '\n' ' '; }
cur_sleep() { tr ' ' '\n' < /sys/power/mem_sleep 2>/dev/null | sed -n 's/^\[\(.*\)\]$/\1/p'; }
driver_bound() { readlink -f "/sys/bus/pci/devices/$BDF/driver" 2>/dev/null | sed 's#.*/##'; }
radio_assoc() {   # the radio is up when the PHY says it is associated -- routing is a different question
  local d; d=$(wifi_dev); [ -n "$d" ] || { printf 'no wifi netdev'; return 1; }
  if iw dev "$d" link 2>/dev/null | grep -q 'Connected to'; then printf 'associated'; return 0; fi
  printf 'not associated'; return 1
}
radio_ping() {    # a ping that must go out of the Wi-Fi interface
  local d gw; d=$(wifi_dev); [ -n "$d" ] || { printf 'n/a'; return 1; }
  gw=$(ip -4 route show dev "$d" 2>/dev/null | awk '/via/{print $3; exit}')
  [ -n "$gw" ] || gw=$(ip -4 route show dev "$d" 2>/dev/null | awk '/proto kernel|scope link/{print $1; exit}' | cut -d/ -f1)
  [ -n "$gw" ] || { printf 'no route on %s' "$d"; return 1; }
  if ping -c1 -W3 -I "$d" "$gw" >/dev/null 2>&1; then printf 'ping %s ok' "$gw"; return 0; fi
  printf 'ping %s FAILED' "$gw"; return 1
}
ath12k_lines() { journalctl -k -b --no-pager -o short-iso 2>/dev/null | grep -E 'ath12k' | tail -6 | sed 's/^/      /'; }
kcount() { journalctl -k -b --no-pager -o cat 2>/dev/null | wc -l; }   # clock-independent: this boot
                                                                       # has no RTC, so --since is not
                                                                       # usable (kernel lines carry the
                                                                       # pre-NTP date)
wait_for_radio() {   # up to $1 seconds for the interface to associate again
  local i=0 d; d=$(wifi_dev)
  while [ "$i" -lt "$1" ]; do
    [ -n "$d" ] && iw dev "$d" link 2>/dev/null | grep -q 'Connected to' && return 0
    sleep 3; i=$((i+3)); d=$(wifi_dev)
  done
  return 1
}

show_state() {
  rule
  say "-- sleep mode"
  say "   /sys/power/state     : $(tr '\n' ' ' < /sys/power/state 2>/dev/null)"
  say "   /sys/power/mem_sleep : $(mem_sleep)   [bracketed = what a plain suspend uses: $(cur_sleep)]"
  say "   persisted at boot    : $TMPFILES $( [ -f "$TMPFILES" ] && tr '\n' ' ' < "$TMPFILES" || echo '(absent -- kernel default: deep)')"
  say "   logind lid policy    : $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | sed 's/^s //; s/"//g; s/^ *//')"
  rule
  say "-- the radio"
  say "   device               : $BDF  $(lspci -nn -s "$BDF" 2>/dev/null | cut -c1-70)"
  say "   driver bound         : $(driver_bound)"
  say "   netdev / association : $(wifi_dev) / $(radio_assoc)  ($(radio_ping))"
  say "   firmware             : $(journalctl -k -b --no-pager -o cat 2>/dev/null | grep -m1 'fw_version' | sed 's/.*fw_version/fw_version/')"
  say "   driver modules       : $(lsmod 2>/dev/null | awk '$1 ~ /^ath12k/{printf "%s(%s) ", $1, $3}')"
  rule
  say "-- this boot's suspends"
  say "   attempts             : $(journalctl -b --no-pager -o cat 2>/dev/null | grep -c 'PM: suspend entry')"
  journalctl -k -b --no-pager -o short-iso 2>/dev/null \
    | grep -E 'PM: suspend (entry|exit)|failed to suspend async|Some devices failed|failed to resume|timeout while waiting for restart|A16: |: A16 ' \
    | tail -12 | sed 's/^/      /'
  say "   [(no lines = this boot has not suspended yet)]"
  rule
  say "-- the staged xhci suspend fix (patches/0010): is it actually the loaded module?"
  say "   installed .ko        : $( [ -f "$UPD/xhci-plat-hcd.ko" ] && printf 'present, srcversion %s' "$(modinfo -F srcversion "$UPD/xhci-plat-hcd.ko" 2>/dev/null)" || echo 'MISSING')"
  say "   loaded srcversion    : $(cat /sys/module/xhci_plat_hcd/srcversion 2>/dev/null)   (stock = $(modinfo -F srcversion /lib/modules/$KVER/kernel/drivers/usb/host/xhci-plat-hcd.ko 2>/dev/null))"
  say "   loaded module params : a16_skip_unsuspended_hcd=$(cat /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd 2>/dev/null || echo 'n/a') a16_state_log=$(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log 2>/dev/null || echo 'n/a')"
  if [ -n "$(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log 2>/dev/null)" ]; then
    say "   => the PATCHED module is loaded: the second-suspend abort is being handled."
  else
    say "   => the STOCK module is loaded, so patches/0010 has never run.  The initramfs built before"
    say "      the fix (see the file list below) is why: 'sudo wifisleep xhci' lands it for this boot,"
    say "      'sudo wifisleep xhci persist' makes it load by itself."
  fi
  if [ "$(id -u)" = 0 ]; then
    local ininitrd
    ininitrd=$(lsinitramfs "$INITRD" 2>/dev/null | grep -c 'xhci-plat-hcd')
    say "   $INITRD: $( [ -s "$INITRD" ] && stat -c '%s bytes, %y' "$INITRD" || echo 'MISSING'), xhci-plat-hcd entries in it: $ininitrd"
    [ "$ininitrd" -gt 0 ] && say "      (an entry there is what gets loaded during the initramfs stage, before /lib/modules is used)"
  else
    say "   $INITRD is root-only; run 'sudo wifisleep' to see whether the initramfs carries the old module."
  fi
  rule
  say "-- the reload hook"
  say "   $HOOK: $( [ -f "$HOOK" ] && echo 'installed' || echo 'not installed')"
  rule
  say "-- what to do next"
  if [ -f "$HOOK" ]; then
    say "   0.  sudo wifisleep hook off     (the hook unloads ath12k, which HANGS this machine: measured"
    say "                                    twice, on a wedged radio and on a healthy one)"
  fi
  if [ -f "/lib/modules/$KVER/updates/a16/ath12k.ko" ]; then
    say "   1.  sudo wifisleep test         (is the radio surviving a suspend with patches/0014 in?)"
    say "   2.  if it is not:  sudo bash ~/a16.sh radiofix revert, then read docs/notes"
  else
    say "   1.  sudo bash ~/a16.sh radiofix        (patches/0014: no SoC reset on resume -- the last"
    say "                                            lever that does not need a suspend to be safe)"
    say "   2.  sudo wifisleep test                (does the radio survive?)"
  fi
  say "   3.  if the screen stays black after a resume: ssh in and read the log rather than"
  say "       power-cycling -- sudo journalctl -k -b | grep -E 'A16: resume|restart complete'"
  say "   4.  the second-suspend abort is separate:  sudo wifisleep xhci persist"
  say "   [s2idle was measured on 2026-09-22 and does NOT protect the radio; the hook and the module"
  say "    swap both crashed the machine -- see BRINGUP/evidence/2026-09-22-ladder-runs.txt]"

}

do_test() {
  case "$N" in ''|*[!0-9]*) say "usage: bash $0 test [count]"; exit 2 ;; esac
  rule
  say "-- suspending $N time(s).  Wake it with the lid, the power button or a key."
  say "   An attempt that cannot sleep returns in about a second and says why."
  say "   If it does not come back and the screen stays black, the machine is often still alive: ssh in"
  say "   and read the log before power-cycling (a hard reset loses it):"
  say "      sudo journalctl -k -b | grep -E 'A16:|restart complete|MHI state|failed to resume'"
  local i=1
  while [ "$i" -le "$N" ]; do
    local mark k0 before after slept wall
    mark=$(date '+%Y-%m-%d %H:%M:%S')
    k0=$(kcount)                      # kernel-log offset; see kcount() for why not --since
    before=$(awk '{printf "%d", $1}' /proc/uptime)
    say ""
    say "   --- attempt $i  ($mark)  mem_sleep=$(cur_sleep)  hook=$( [ -f "$HOOK" ] && echo yes || echo no)  radio=$(radio_assoc) ---"
    local susp_out=""
    if [ "$DRY" = 1 ]; then say "   [dry-run] systemctl suspend"; else susp_out=$(systemctl suspend 2>&1); fi
    [ -n "$susp_out" ] && printf '%s\n' "$susp_out" | sed 's/^/      ! /' 
    after=$(awk '{printf "%d", $1}' /proc/uptime)
    wall=$(( $(date +%s) - $(date -d "$mark" +%s) ))
    slept=$((after-before))
    kslice() { journalctl -k -b --no-pager "$@" 2>/dev/null | tail -n +$((k0+1)); }
    say "      away: ${slept}s uptime / ${wall}s wall"
    kslice -o short-iso \
      | grep -E 'PM: suspend (entry|exit)|failed to suspend async|Some devices failed|failed to resume|timeout while waiting for restart|dpm_run_callback|A16: |: A16 ' \
      | sed 's/^/      /'
    if kslice -o cat | grep -qE 'Some devices failed to suspend|failed to suspend async'; then
      say "      SUSPEND: ABORTED -- $(kslice -o cat | grep -oE '[a-z0-9.-]+: PM: failed to suspend' | head -1 | sed 's/: PM.*//') refused it (-22 = xhci_suspend(): the USB core left the HCD unsuspended)."
      say "               'sudo wifisleep xhci' is the fix for this one."
      i=$((i+1)); continue
    fi
    if printf '%s' "$susp_out" | grep -qiE 'failed|masked|inhibit|denied|not supported'; then
      say "      SUSPEND: NOT ATTEMPTED -- the request was refused:"
      say "               $(printf '%s' "$susp_out" | head -1)"
      say "               [a masked sleep.target (sudo ~/a16step nosleep) refuses it; unmask with"
      say "                'sudo ~/a16step nosleep off' and try again -- this run says nothing about the radio]"
      i=$((i+1)); continue
    fi
    if [ "$slept" -lt 5 ] && ! kslice -o cat | grep -q 'PM: suspend entry'; then
      say "      SUSPEND: no sleep happened (uptime went ${slept}s and there is no 'PM: suspend entry'"
      say "               in the kernel log) -- read the lines above for why.  This run says nothing"
      say "               about the radio."
      i=$((i+1)); continue
    fi
    say "      SUSPEND: slept (${slept}s uptime)."
    say "      RADIO  : waiting up to 60 s for the interface to come back..."
    if wait_for_radio 60; then
      say "      RADIO  : SURVIVED -- $(radio_assoc), $(radio_ping)"
    else
      say "      RADIO  : GONE -- $(radio_assoc), $(radio_ping).  The kernel's last words:"
      ath12k_lines
      say "      => the radio did not survive.  Next: $NEXT_HINT"
    fi
    i=$((i+1))
    [ "$i" -le "$N" ] && { say ""; say "   next attempt in 5 s"; sleep 5; }
  done
  rule
  say "log: $LOG"
}

do_s2idle() {
  case "$ARG" in on|off) ;; *) say "usage: bash $0 s2idle on|off"; exit 2 ;; esac
  rule
  say "-- mem_sleep -> $ARG"
  if [ "$ARG" = on ]; then
    run sh -c 'echo s2idle > /sys/power/mem_sleep'
    [ "$DRY" = 1 ] || { printf 'w /sys/power/mem_sleep - - - - s2idle\n' > "$TMPFILES"; }
    say "   /sys/power/mem_sleep : $(mem_sleep)"
    say "   persisted            : $TMPFILES -> s2idle (applied at every boot by systemd-tmpfiles)"
  else
    local support
    support=$(cat /sys/power/mem_sleep 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
    if [ "$support" = "s2idle" ]; then
      run sh -c 'echo deep > /sys/power/mem_sleep'
      say "   /sys/power/mem_sleep : $(mem_sleep)"
    else
      say "   already $(cur_sleep) (the kernel picked it; nothing written)"
    fi
    run rm -f "$TMPFILES"
    say "   persisted            : $( [ -f "$TMPFILES" ] && echo kept || echo 'removed (kernel default returns at the next boot)')"
  fi
  say ""
  say "   s2idle keeps the platform awake and still runs every driver's suspend callback, so it"
  say "   answers one question: does the platform's deep-suspend power (PCIe link / endpoint rail)"
  say "   kill this radio, or does ath12k's own resume sequence?  Measure it:  sudo wifisleep test"
}

do_hook() {
  case "$ARG" in test|on|off) ;; *) say "usage: bash $0 hook test|on|off"; exit 2 ;; esac
  rule
  case "$ARG" in
  test)
    say "-- driver reload, now, on the running system (no suspend involved)"
    say "   what it does: modprobe -r ath12k_wifi7 ath12k ; echo 1 > /sys/bus/pci/rescan ; modprobe ath12k_wifi7"
    if [ "$GATE" != 1 ]; then
      say ""
      say "   REFUSING: this hangs the machine.  Measured twice now -- on a wedged radio (2026-09-17,"
      say "   15:12, needed a hard reset) and again on a *healthy* one (2026-09-22 08:55): the"
      say "   'modprobe -r ath12k_wifi7 ath12k' step never returns and the machine stops responding."
      say "   So the reload-across-suspend idea is dead on this kernel, and so are the driver-teardown"
      say "   rungs of reload_wifi.  The lever that is left is the driver patch:  ~/a16.sh radiofix"
      say ""
      say "   (A16_I_KNOW=1 runs it anyway, for a machine you are willing to restart by hand.)"
      exit 0
    fi
    say "   A16_I_KNOW=1: running it anyway."
    say ""
    say "   before: netdev=$(wifi_dev) driver=$(driver_bound) $(radio_assoc)"
    run modprobe -r ath12k_wifi7 ath12k; local rc=$?
    say "   modprobe -r exit     : $rc"
    sleep 2
    say "   after unload         : netdev=$(wifi_dev) driver=$(driver_bound)"
    run sh -c 'echo 1 > /sys/bus/pci/rescan'
    run modprobe ath12k_wifi7; rc=$?
    say "   modprobe exit        : $rc"
    if wait_for_radio 90; then
      say "   VERDICT: the radio came back ($(radio_assoc), $(radio_ping)) -- the reload is safe on a"
      say "            healthy radio, so the sleep hook is worth testing:  sudo wifisleep hook on"
    else
      say "   VERDICT: the radio did NOT come back after a reload.  Do not install the hook;"
      say "            'sudo wifisleep forensics' is the next thing to read."
      ath12k_lines
    fi
    ;;
  on)
    if [ "$GATE" != 1 ]; then
      say "REFUSING to install the hook: it runs 'modprobe -r ath12k_wifi7 ath12k' before every suspend,"
      say "and that command hangs this machine (measured 2026-09-17 on a wedged radio and 2026-09-22 on a"
      say "healthy one).  Use the driver patch instead:  sudo bash ~/a16.sh radiofix"
      exit 0
    fi
    say "-- installing $HOOK"
    if [ "$DRY" != 1 ]; then
      cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
# Written by a16-wifi-sleep.sh -- the QCC2072 (ath12k) resume path cannot re-init its firmware after
# a deep suspend (see BRINGUP/tools/a16-wifi-sleep.sh), so the driver is taken off the device before
# the suspend and the device is re-probed after it -- the same thing a boot does.
case "$1" in
  pre)
    modprobe -r ath12k_wifi7 ath12k 2>/dev/null
    ;;
  post)
    # the platform may have taken the PCIe link down; make sure the device is on the bus again
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    modprobe ath12k_wifi7 2>/dev/null
    ;;
esac
exit 0
HOOKEOF
      chmod 755 "$HOOK"
    fi
    say "   installed: $( [ -f "$HOOK" ] && echo yes || echo NO)"
    say "   now measure it:  sudo wifisleep test"
    ;;
  off)
    run rm -f "$HOOK"
    say "   removed  : $( [ -f "$HOOK" ] && echo 'still there!' || echo yes)"
    ;;
  esac
}

do_xhci() {
  rule
  if [ "$ARG" = persist ]; then
    say "-- rebuild the initramfs so the patched xhci-plat-hcd.ko is what loads"
    say "   the fix is in $UPD/xhci-plat-hcd.ko, and modules.dep already prefers it -- but the module"
    say "   is loaded during the initramfs stage, from the copy that initramfs carries, and that copy"
    say "   was built before the fix existed.  So it has to be rebuilt (or the module swapped at boot;"
    say "   this rebuild is the honest fix)."
    local oldlist newlist
    [ -f "$UPD/xhci-plat-hcd.ko" ] || { say "   $UPD/xhci-plat-hcd.ko is MISSING -- run: sudo bash ~/a16.sh suspendfix"; exit 1; }
    say "   initramfs before     : $( [ -s "$INITRD" ] && stat -c '%s bytes %y' "$INITRD" || echo MISSING)"
    if [ "$DRY" = 1 ]; then
      say "   [dry-run] cp $INITRD $INITRD.a16bak"
      say "   [dry-run] lsinitramfs $INITRD > /tmp/a16-initrd-old.list"
      say "   [dry-run] update-initramfs -c -k $KVER"
      say "   [dry-run] verify the new initramfs: same file list + this module"
      return 0
    fi
    [ -s "$INITRD" ] || { say "   no initramfs at $INITRD -- nothing to rebuild"; exit 1; }
    cp -a "$INITRD" "$INITRD.a16bak" || { say "   could not write $INITRD.a16bak -- stopping"; exit 1; }
    say "   backup               : $INITRD.a16bak"
    lsinitramfs "$INITRD" 2>/dev/null | sort > /tmp/a16-initrd-old.list
    say "   rebuilding (update-initramfs -c -k $KVER) -- 1-2 minutes, output below if it fails"
    update-initramfs -c -k "$KVER" || { say "   update-initramfs FAILED -- the old initramfs is untouched at $INITRD.a16bak"; exit 1; }
    say "   initramfs after      : $(stat -c '%s bytes %y' "$INITRD")"
    lsinitramfs "$INITRD" 2>/dev/null | sort > /tmp/a16-initrd-new.list
    newlist=$(grep -c . /tmp/a16-initrd-new.list); oldlist=$(grep -c . /tmp/a16-initrd-old.list)
    say "   file count            : $oldlist -> $newlist"
    say "   differences (only these should appear):"
    diff /tmp/a16-initrd-old.list /tmp/a16-initrd-new.list | grep -E '^[<>]' | head -20 | sed 's/^/      /'
    if grep -q 'nvme' /tmp/a16-initrd-new.list; then say "   nvme in the new initramfs: yes (the root device's driver)"; else say "   nvme NOT in the new initramfs: do not reboot, tell me"; exit 1; fi
    if lsinitramfs "$INITRD" 2>/dev/null | grep -q 'updates/a16/xhci-plat-hcd.ko'; then
      say "   VERIFIED: updates/a16/xhci-plat-hcd.ko is inside the new initramfs."
    else
      say "   NOT in the initramfs: the patch still will not load.  Stopping (old file kept as .a16bak)."; exit 1
    fi
    say ""
    say "NEXT: reboot into [3], then"
    say "      sudo wifisleep                             (the parameters must be present)"
    say "      sudo lid_sleep test 2                      (both attempts must sleep)"
    say "   if the machine does not come up: boot entry [1]/[2] and restore with"
    say "      cp /boot/initrd.img-$KVER.a16bak /boot/initrd.img-$KVER"
    return 0
  fi

  if [ "$GATE" != 1 ]; then
    say "-- the module swap is REFUSED by default: on 2026-09-22 this ran cleanly (the patched module"
    say "   loaded, srcversion verified) and the *next* resume left the screen black with no keyboard"
    say "   backlight, so the machine had to be restarted -- i.e. the swap itself is not safe, most"
    say "   likely because unloading xhci-plat-hcd tears the USB controllers down and re-creates them."
    say ""
    say "   The fix should be made to load by itself instead, with no swap at runtime:"
    say ""
    say "       sudo wifisleep xhci persist      (rebuilds the initramfs, with a backup and a check)"
    say ""
    say "   (A16_I_KNOW=1 swaps it anyway.)"
    return 0
  fi
  say "-- landing patches/0010 for this boot: swap the running xhci-plat-hcd module"
  say "   installed            : $( [ -f "$UPD/xhci-plat-hcd.ko" ] && modinfo -F srcversion "$UPD/xhci-plat-hcd.ko" || echo MISSING)"
  say "   loaded (stock)       : $(cat /sys/module/xhci_plat_hcd/srcversion 2>/dev/null)"
  say "   USB devices now      : $(lsusb 2>/dev/null | wc -l)  [they will re-enumerate; root is NVMe and the internal input is I2C, so a failed swap costs a reboot, nothing else]"
  run modprobe -r xhci_plat_hcd; say "   modprobe -r exit     : $?"
  sleep 2
  run modprobe xhci_plat_hcd; say "   modprobe exit        : $?"
  sleep 3
  say "   loaded srcversion    : $(cat /sys/module/xhci_plat_hcd/srcversion 2>/dev/null)"
  if [ -n "$(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log 2>/dev/null)" ]; then
    say "   VERIFIED: the patched module is loaded (a16_skip_unsuspended_hcd=$(cat /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd), a16_state_log=$(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log))."
    say "   now:  sudo wifisleep test 2     (the second suspend must sleep; the A16 lines name the cause)"
  else
    say "   NOT the patched module.  Unload it and load ours by path, then re-check:"
    say "      sudo modprobe -r xhci_plat_hcd && sudo modprobe -r $UPD/xhci-plat-hcd.ko"
  fi
  say "   for every boot, without the swap:  sudo wifisleep xhci persist"
}

do_forensics() {
  rule
  say "-- post-wedge forensics: is the device still on the bus, and can it be recovered without a reboot?"
  say "   bus state (a live config space means the platform kept the endpoint powered and the fault is"
  say "   in the firmware/MHI handshake; 0xffffffff or a vanished device means the platform powered it"
  say "   off during the suspend and no driver change can fix that):"
  say "      $(lspci -nn -s "$BDF" 2>/dev/null || echo 'device is NOT on the bus')"
  say "      power_state    : $(cat /sys/bus/pci/devices/$BDF/power_state 2>/dev/null)"
  say "      enable/wakeup  : enable=$(cat /sys/bus/pci/devices/$BDF/enable 2>/dev/null) wakeup=$(cat /sys/bus/pci/devices/$BDF/power/wakeup 2>/dev/null)"
  say "      config space   : $(lspci -xxx -s "$BDF" 2>/dev/null | head -2 | tail -1 | awk '{print $2, $3, $4}' | sed 's/^\(.\{0,24\}\).*/\1/')"
  say "      driver bound   : $(driver_bound)"
  say "      netdev         : $(wifi_dev)  radio=$(radio_assoc)"
  say "   kernel:"; ath12k_lines
  rule
  say "-- recovery attempt 1: PCI function reset, then rebind (no module unload)"
  if [ "$GATE" != 1 ] && [ "$DRY" != 1 ]; then
    say "   this writes to $BDF's config space and rebinds the driver.  Re-run with A16_I_KNOW=1 to try it."
  else
    run sh -c "echo 1 > /sys/bus/pci/devices/$BDF/reset"; say "   reset exit        : $?"
    sleep 3
    run sh -c "echo $BDF > /sys/bus/pci/drivers/ath12k_wifi7_pci/unbind 2>/dev/null; echo $BDF > /sys/bus/pci/drivers/ath12k_wifi7_pci/bind"; say "   rebind exit       : $?"
    if wait_for_radio 60; then say "   VERDICT: the radio is back -- a reboot is not needed for this wedge."
    else say "   VERDICT: no netdev after the reset+rebind."; fi
    say ""
    say "-- recovery attempt 2 (last resort, and it is the one that froze the machine on 2026-09-17):"
    say "   modprobe -r ath12k_wifi7 ath12k  -- only if attempt 1 failed and you accept a hard reset."
  fi
  rule
  say "the honest summary of the 2026-09-17 ladder: nothing in software recovered a wedged radio.  This"
  say "mode exists to answer *why* on the next wedge (bus vs firmware), which decides the fix."
}

say "=== wifisleep  (a16-wifi-sleep.sh)  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE${ARG:+ $ARG} ==="
say "kernel: $KVER   boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "log   : $LOG"
[ "$DRY" = 1 ] && say "A16_DRY=1: every command is printed, nothing on the machine changes."
NEXT_HINT="sudo ~/a16.sh radiofix   (the driver: keep the device, re-attach to it) -- see docs"

case "$MODE" in
  status) show_state ;;
  test)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo wifisleep test $N"; say ""; exit 1; }
    show_state; do_test ;;
  s2idle)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo wifisleep s2idle $ARG"; say ""; exit 1; }
    do_s2idle ;;
  hook)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo wifisleep hook $ARG"; say ""; exit 1; }
    do_hook ;;
  xhci)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo wifisleep xhci ${ARG:+$ARG}"; say ""; exit 1; }
    do_xhci ;;
  forensics)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo wifisleep forensics"; say ""; exit 1; }
    do_forensics ;;
  *) say "usage: wifisleep [status|test [n]|s2idle on|off|hook test|on|off|xhci [persist]|forensics]"; say "       wifisleep --help"; exit 2 ;;
esac
say ""
say "log: $LOG"
