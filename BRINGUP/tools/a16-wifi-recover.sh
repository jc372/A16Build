#!/usr/bin/env bash
# a16-wifi-recover.sh -- bring the Wi-Fi radio back after a suspend/resume wedge, without rebooting.
#
# The operator-facing command is `reload_wifi` (symlinked into /usr/local/bin and into the home
# directory by tools/a16-install-console-commands.sh, so plain `reload_wifi` works; the equivalent
# through the old single entry point is `sudo bash ~/a16.sh wifi`).
#
#   reload_wifi --help                  this text
#   sudo reload_wifi                    diagnose, then the two soft rungs (NetworkManager, supplicant)
#   reload_wifi status                  read-only, no root: what state the radio is in
#   A16_I_KNOW=1 sudo reload_wifi hard  rungs h1-h4: everything that touches the driver -- see below
#
# Why this exists.  The failure that needs a reboot is not a NetworkManager problem and not a board-data
# problem: the radio's *firmware* stops answering.  Every instance of it on 2026-09-17 followed a
# suspend/resume, and the resume side is where it breaks (boot ids 20167034 and 3a63a313):
#
#   PM: suspend entry (deep)                                  <- lid closed, logind suspends
#   ath12k_wifi7_pci 0004:01:00.0: timeout while waiting for restart complete
#   ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110
#   ath12k_wifi7_pci 0004:01:00.0: PM: failed to resume async: error -110
#   PM: suspend exit
#
# From then on the WMI (firmware command) channel is dead and never comes back, so the interface cannot
# even be brought up -- which is what the desktop shows as "no networks found", with the radio plainly
# present in Settings:
#
#   ath12k_wifi7_pci 0004:01:00.0: wmi command 16387 timeout          (repeats)
#   ath12k_wifi7_pci 0004:01:00.0: failed to send WMI_PDEV_SET_PARAM cmd
#   ath12k_wifi7_pci 0004:01:00.0: fail to start mac operations in pdev idx 0 ret -11
#   wpa_supplicant: Could not set interface wlP4p1s0 flags (UP): Resource temporarily unavailable
#   NetworkManager: device (wlP4p1s0): supplicant interface keeps failing, giving up
#
# `-11` is EAGAIN coming back from the firmware channel, not a permission or a profile problem.  That is
# why restarting NetworkManager alone does not help: the wedge is below it, in the firmware/MHI layer.
#
# What the two layers do, measured on 2026-09-17 (boot e090779e, log
# ~/a16-payload/wifi-recover-20260917-150949.log):
#
#   rung 1  restart NetworkManager          no effect -- the interface cannot come up (state 'unavailable')
#   rung 2  restart wpa_supplicant + NM     no effect, same reason
#   rung 3  unbind / bind ath12k_wifi7_pci  unbind succeeds and the netdev disappears; the bind does NOT
#                                           bring the device back (no probe, no netdev, 45 s)
#   rung 4  unload / reload the modules     **the whole machine froze at 'modprobe -r'** -- a hard reset
#                                           was the only way out
#
# So there is no software recovery from this wedge in this kernel: the soft rungs are harmless, and
# everything that tears the driver down is either useless or freezes the machine.  A wedged radio means
# a reboot.  What is worth doing instead is not getting wedged: the wedge happens on the resume of the
# one suspend per boot that completes, so  `sudo lid_sleep lid ignore`  (a closed lid does nothing)
# keeps the radio alive at the cost of never sleeping -- see docs/suspend.md.
#
# The `hard` rungs stay in here for a boot where the radio is NOT wedged (there they are the normal
# ways to reset a driver) and for the next attempt on a wedged one if someone wants the evidence:
#
#   h1  PCI function reset in place       echo 1 > .../0004:01:00.0/reset   (no driver teardown; untested)
#   h2  unbind / bind the PCI driver      (proven not to work after a wedge -- rung 3 above)
#   h3  PCI function remove + bus rescan  (same remove path as h4)
#   h4  unload / reload ath12k_wifi7      (proven to freeze the machine after a wedge -- rung 4 above)
#
# Logged to ~/a16-payload/wifi-recover-<timestamp>.log so it survives a power cycle.
# Env overrides: A16_IFACE, A16_PCI, A16_PCI_DRV, A16_WAIT (seconds per rung), A16_SKIP_ROOT (1 = run the
# ladder without root, on a machine where the commands are harmless), A16_DRY (1 = print, do not run),
# A16_LOG, A16_FORCE (1 = do not stop when the session runs over the interface being restarted).
set -u

MODE="${1:-recover}"
IFACE="${A16_IFACE:-wlP4p1s0}"
PCI="${A16_PCI:-0004:01:00.0}"
DRV="${A16_PCI_DRV:-ath12k_wifi7_pci}"
MODS="${A16_MODS:-ath12k_wifi7 ath12k}"
WAIT="${A16_WAIT:-45}"            # seconds to wait for an association after each rung
SKIP_ROOT="${A16_SKIP_ROOT:-0}"
DRY="${A16_DRY:-0}"
FORCE="${A16_FORCE:-0}"
I_KNOW="${A16_I_KNOW:-0}"
LOG="${A16_LOG:-/home/jc/a16-payload/wifi-recover-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }

usage() {
  cat <<'EOF'
reload_wifi -- bring the Wi-Fi radio back after a suspend/resume wedge, without rebooting.

usage:
  reload_wifi --help            this text
  reload_wifi status            read-only dump, no root: interface, driver, is it the firmware wedge,
                                and what the suspend/resume of this boot did
  sudo reload_wifi              diagnose, then the two soft rungs (what this does by default)
  sudo reload_wifi soft         the same two rungs only
  A16_I_KNOW=1 sudo reload_wifi hard   the four driver-teardown rungs, in this order:
                                h1 PCI function reset in place (untested)
                                h2 unbind / bind the PCI driver
                                h3 PCI function remove + bus rescan
                                h4 unload / reload ath12k_wifi7 + ath12k

what is measured (2026-09-17, boot e090779e):
  the soft rungs do nothing -- after a resume the firmware never answers again, so the interface
  cannot be brought up, and NetworkManager/wpa_supplicant are not where the fault is;
  'hard' on a wedged radio does NOT recover it: h2 leaves the netdev gone, and h4 (modprobe -r)
  FROZE THE WHOLE MACHINE, needing a hard reset.  It is gated behind A16_I_KNOW=1 for that reason.

so: a wedged radio means a reboot, and the thing that avoids it is not suspending on the lid,
    `sudo lid_sleep lid ignore`   (see docs/suspend.md -- the wedge lands on the resume).

log: ~/a16-payload/wifi-recover-<timestamp>.log
env: A16_WAIT (seconds per rung, default 45), A16_I_KNOW=1 (allow the hard rungs), A16_FORCE=1
     (proceed even if a session would drop or the radio looks healthy), A16_DRY=1 (print, run none).
EOF
}

# --help before anything else: no log file, no root check.
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

# run a command, echoing it first; honours $DRY
do_cmd() {
  say "   \$ $*"
  [ "$DRY" = 1 ] && return 0
  "$@"
}
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

[ "$MODE" = status ] || [ "$MODE" = soft ] || [ "$MODE" = hard ] || [ "$MODE" = recover ] || \
  [ "$MODE" = driver ] || [ "$MODE" = reset ] || \
  { say "usage: bash $0 [recover|status|soft|hard]   (reload_wifi --help)"; exit 2; }
[ "$MODE" = status ] || \
  { [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || {
      say "This needs root.  Type exactly:"
      say ""
      say "    sudo reload_wifi"
      say ""
      exit 1; }; }

# ---------------------------------------------------------------- probes (read-only)
nm_state()   { nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2}'; }
nm_conn()    { nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null | awk -F: -v i="$IFACE" '$1==i && $2=="connected"{print $3}'; }
if_present() { [ -e "/sys/class/net/$IFACE" ]; }
pci_driver() { local d; d=$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null); [ -n "$d" ] && basename "$d" || printf '<no driver bound>'; }
mods_loaded() { lsmod | awk -v m="$MODS" 'BEGIN{n=split(m,a," ")} {for(i=1;i<=n;i++) if($1==a[i]) c++} END{print c+0}'; }
wedge_lines() { journalctl -k -b --no-pager -o cat 2>/dev/null | grep -cE 'ath12k.*(wmi command [0-9]+ timeout|failed to resume core|fail to start mac operations|failed to resume async)'; }
resume_fail_lines() { journalctl -k -b --no-pager -o short-iso 2>/dev/null | grep -E 'ath12k.*(failed to resume (core|async)|timeout while waiting for restart complete)' | tail -3; }
suspend_events() { journalctl -b --no-pager -o short-iso 2>/dev/null | grep -cE "logind.*(Suspending|Operation 'suspend' finished)"; }

wait_for_conn() {   # up to $WAIT s; prints a dot every 5 s; returns 0 when associated
  local t=0 st
  if [ "$DRY" = 1 ]; then say "   (dry run: not waiting for an association)"; return 0; fi
  while [ "$t" -lt "$WAIT" ]; do
    st=$(nm_state)
    if [ "$st" = connected ]; then say "   associated: $(nm_conn)  (after ${t}s)"; return 0; fi
    printf '   waiting (%ss: state=%s)\n' "$t" "${st:-<no device>}"
    sleep 5; t=$((t+5))
  done
  return 1
}

dump_status() {
  rule
  say "-- the interface"
  say "   iface         : $IFACE (present: $(if_present && echo yes || echo 'no'))"
  say "   NetworkManager: state=$(nm_state) connection=$(nm_conn)"
  if [ -e "/sys/class/net/$IFACE" ]; then
    say "   operstate     : $(cat /sys/class/net/$IFACE/operstate 2>/dev/null)   carrier: $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"
    say "   addresses     : $(ip -brief addr show "$IFACE" 2>/dev/null | tr -s ' ')"
    say "   link          : $(iw dev "$IFACE" link 2>/dev/null | grep -E 'SSID|freq|signal|bitrate' | tr -s ' ' | tr '\n' ' ')"
  fi
  rule
  say "-- the driver and the PCI function"
  say "   modules loaded: $(mods_loaded)/2 of '$MODS'"
  say "   $PCI driver  : $(pci_driver)"
  say "   firmware files: $(ls /lib/firmware/ath12k/*/hw2.0/*.zst 2>/dev/null | wc -l) present under /lib/firmware/ath12k"
  rule
  say "-- is this the firmware wedge, or something else?"
  say "   ath12k wedge lines in this boot's kernel log: $(wedge_lines)"
  say "   [(0 means the firmware has not complained in this boot; a non-zero count is the wedge:"
  say "     WMI command timeouts / a failed resume, after which the interface cannot come up)]"
  if [ "$(wedge_lines)" != 0 ]; then
    say "   first lines of it:"
    resume_fail_lines | sed 's/^/      /'
  fi
  rule
  say "-- why it happens: suspend/resume activity in this boot"
  say "   logind suspend entries: $(suspend_events)"
  journalctl -b --no-pager -o short-iso 2>/dev/null \
    | grep -E "logind.*(Suspending|Operation 'suspend' finished|Lid (closed|opened))" | tail -6 | sed 's/^/      /'
  journalctl -k -b --no-pager -o short-iso 2>/dev/null \
    | grep -E 'PM: suspend (entry|exit)|failed to suspend|failed to resume|Some devices failed|A16 ' | tail -8 | sed 's/^/      /'
  rule
  say "   [(a 'Suspending...' followed 3 s later by 'finished', repeating while the lid is shut, is the"
  say "     suspend attempt aborting -- see docs/suspend.md.  The ath12k resume failure lands on the first"
  say "     real suspend/resume of the boot, which is when the radio goes away.)]"
}

# ---------------------------------------------------------------- rungs
rung_nm() {
  rule
  say "-- rung 1: restart NetworkManager"
  do_cmd systemctl restart NetworkManager || return 1
  wait_for_conn
}

rung_supplicant() {
  rule
  say "-- rung 2: restart wpa_supplicant"
  if ! systemctl list-unit-files wpa_supplicant.service >/dev/null 2>&1; then
    say "   no wpa_supplicant.service on this system (NetworkManager drives it over D-Bus) -- skipped"
    return 1
  fi
  do_cmd systemctl restart wpa_supplicant || say "   restart returned non-zero (it may be D-Bus activated)"
  do_cmd systemctl restart NetworkManager || true
  wait_for_conn
}

rung_h1_reset() {
  rule
  say "-- rung h1: PCI function reset in place (no driver teardown; untested on this machine)"
  do_cmd sh -c "echo 1 > /sys/bus/pci/devices/$PCI/reset" || return 1
  sleep 3
  wait_for_conn
}

rung_h2_rebind() {
  if [ "${A16_IKNOW:-}" != 1 ]; then
    say "-- this rung is DISABLED: it hangs the machine, and the hang is worse than a dead radio."
    say "   unbind (h2) blocks in mhi_power_down -> flush_work as soon as the MHI is wedged --"
    say "     schedule_timeout -> wait_for_completion -> __flush_work -> __mhi_power_down -> ath12k_mhi_stop"
    say "       -> ath12k_pci_power_down -> ath12k_core_deinit -> ath12k_pci_remove -> unbind_store"
    say "   (measured 2026-09-22 12:33) -- and the shell then sits in D state, which makes every later"
    say "   suspend fail ('Freezing user space processes failed after 20 s: 1 tasks refusing to freeze')"
    say "   and takes the network with it.  modprobe -r (h4) does the same thing."
    say "   A16_IKNOW=1 in front of the command runs it anyway; expect to need a reboot."
    return 1
  fi
  rule
  say "-- rung h2: unbind / bind the PCI driver"
  say "   (measured 2026-09-17 after a wedge: unbind succeeds and the netdev goes away, the bind does not"
  say "    bring the device back -- if that happens here again, the radio is gone until a reboot)"
  local d=/sys/bus/pci/drivers/$DRV
  [ -d "$d" ] || { say "   $d is missing -- is the driver loaded?"; return 1; }
  do_cmd sh -c "echo '$PCI' > $d/unbind" || return 1
  do_cmd sh -c "echo '$PCI' > $d/bind" || return 1
  wait_for_conn
}

rung_h3_pci() {
  rule
  say "-- rung h3: PCI function remove + bus rescan (takes the function off the bus and finds it again)"
  do_cmd sh -c "echo 1 > /sys/bus/pci/devices/$PCI/remove" || return 1
  sleep 2
  do_cmd sh -c "echo 1 > /sys/bus/pci/rescan" || return 1
  sleep 3
  wait_for_conn
}

rung_h4_reload() {
  rule
  say "-- rung h4: unload / reload $MODS"
  say "   (measured 2026-09-17 after a wedge: the machine froze inside this unload and needed a hard reset)"
  [ "${A16_IKNOW:-}" = 1 ] || { say "-- disabled (see h2 above: modprobe -r hangs the same way); A16_IKNOW=1 to try"; return 1; }
  do_cmd timeout 30 modprobe -r $MODS
  local rc=$?
  [ "$rc" = 0 ] && say "   unloaded" || say "   unload returned $rc (124 = it did not finish in 30 s)"
  do_cmd modprobe ath12k_wifi7
  wait_for_conn
}

brief() {
  rule
  say "-- state now"
  say "   iface $IFACE: present=$(if_present && echo yes || echo no)  nm=$(nm_state)  connection=$(nm_conn)"
  say "   wedge lines this boot: $(wedge_lines)"
}

CMD=$(basename "$0"); case "$CMD" in reload_wifi|lid_sleep) ;; *) CMD=reload_wifi ;; esac
say "=== $CMD  (a16-wifi-recover.sh)  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
say "kernel: $(uname -r)   boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "log   : $LOG"

case "$MODE" in
  status) dump_status; say ""; say "log: $LOG"; exit 0 ;;
  soft|hard|recover) ;;
  driver|reset)
    say "mode '$MODE' is gone: those rungs are now 'hard', and they need A16_I_KNOW=1"
    say "(they do not recover a wedged radio, and the module unload froze this machine on 2026-09-17)"
    exit 2 ;;
  *) say "usage: bash $0 [recover|status|soft|hard]   (reload_wifi --help)"; exit 2 ;;
esac

if [ "$MODE" = hard ] && [ "$I_KNOW" != 1 ] && [ "$DRY" != 1 ]; then
  say ""
  say "! The 'hard' rungs touch the driver, and on this machine that has not ended well:"
  say "    2026-09-17, after a resume wedge -- h2 (bind) left the netdev gone, h4 (modprobe -r) FROZE the"
  say "    whole machine; a hard reset was the only way out.  They do not recover a wedged radio."
  say ""
  say "  Read docs/wifi.md first.  To run them anyway:"
  say ""
  say "      A16_I_KNOW=1 sudo reload_wifi hard"
  say ""
  say "  The default (sudo reload_wifi) is the two soft rungs, which are harmless."
  exit 4
fi

if [ -n "${SSH_CONNECTION:-}" ] && [ "$FORCE" != 1 ]; then
  peer="${SSH_CONNECTION%% *}"
  say ""
  say "! This session came in over the network from $peer."
  say "  If that path uses $IFACE, the restart will drop the session (the script keeps running; the log"
  say "  is on disk).  To go ahead anyway:  A16_FORCE=1 sudo reload_wifi"
  ( ip route get "$peer" 2>/dev/null | grep -q "dev $IFACE" ) && { say "  (checked: the route to $peer does use $IFACE -- the session will drop)"; exit 3; }
  say "  (checked: the route to $peer does not use $IFACE)"
fi

dump_status
rule

# Nothing to fix: if the interface is already associated and the firmware has not complained this boot,
# do not touch a working radio (that is what a restart of NetworkManager would do to the session too).
if [ "$MODE" = recover ] && [ "$DRY" != 1 ] && [ "$(nm_state)" = connected ] && [ "$(wedge_lines)" = 0 ]; then
  say "Nothing to fix: $IFACE is already associated with '$(nm_conn)' and this boot's kernel log has no"
  say "ath12k wedge line.  (To restart it anyway:  A16_FORCE=1 sudo reload_wifi)"
  rule
  say "log: $LOG"
  exit 0
fi

say "-- climbing the ladder; the first rung that gets an association is the last one that runs"

WON=""
try_rung() {
  local name=$1; shift
  if "$@"; then WON="$name"; return 0; fi
  say "   -> not back after '$name'"
  brief
  return 1
}

case "$MODE" in
  soft|recover) try_rung "nm" rung_nm || try_rung "supplicant" rung_supplicant ;;
  hard)
    try_rung "h1-reset" rung_h1_reset \
      || try_rung "h2-rebind" rung_h2_rebind \
      || try_rung "h3-pci" rung_h3_pci \
      || try_rung "h4-reload" rung_h4_reload ;;
esac

rule
if [ "$DRY" = 1 ]; then
  say "RESULT: dry run -- no command was executed.  Without A16_DRY=1 the ladder runs for real,"
  say "        cheapest rung first, and stops at the first one that gets an association."
elif [ -n "$WON" ]; then
  say "RESULT: Wi-Fi is back -- associated with '$(nm_conn)' after rung '$WON'."
  say "        No reboot was needed.  That the soft rungs were enough means the firmware was fine and"
  say "        NetworkManager had given up; a 'hard' rung means the firmware was wedged and re-probing the"
  say "        device cured it (worth recording: it has not been the case on this machine yet)."
  rc=0
else
  if [ "$MODE" = hard ]; then
    say "RESULT: still not associated after the hard rungs."
  else
    say "RESULT: still not associated.  The firmware wedge is below NetworkManager, and on this kernel"
    say "        there is nothing left to try from software that is safe:"
    say "          - 2026-09-17 after a resume wedge, unbind/bind (h2) left the netdev gone,"
    say "          - and the module unload (h4, modprobe -r) froze the whole machine."
    say "        (The same four rungs are behind:  A16_I_KNOW=1 sudo reload_wifi hard)"
  fi
  if if_present; then
    say "        The interface is there ($(nm_state)) and will not come up -- reboot."
  else
    say "        The netdev is gone (the driver was unbound and not re-probed) -- reboot."
  fi
  say "        To stop this happening again: the wedge lands on the resume of the one suspend per boot"
  say "        that completes, so a closed lid is what costs the radio."
  say "            sudo lid_sleep lid ignore      # a closed lid does nothing; the radio survives"
  say "        Kernel lines from the last 30:"
  journalctl -k -b --no-pager -o short-iso 2>/dev/null | grep -iE 'ath12k|0004:01:00.0|mhi' | tail -15 | sed 's/^/           /'
  rc=1
fi
rule
say "log: $LOG"
exit ${rc:-0}
