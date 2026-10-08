#!/usr/bin/env bash
# a16-sleep-test.sh -- what the lid does, whether this machine can suspend, and what stops it.
#
#   lid_sleep --help                    this text
#   lid_sleep status                    read-only, no root: the state, and why the lid loops
#   sudo lid_sleep test                 suspend once, report what happened
#   sudo lid_sleep test 2               twice (the two attempts differ -- see below)
#   sudo lid_sleep lid ignore           a closed lid does nothing at all
#   sudo lid_sleep lid suspend          back to the systemd default
#   sudo lid_sleep debug                arm a resume-debug boot on entry [3]: no_console_suspend +
#                                       initcall_debug + pm_debug_messages, so a resume that stalls
#                                       prints where it stopped on the panel itself.  'debug off' removes it
#   sudo lid_sleep measure              suspend once and report, from the journal and the battery, how
#                                       long it stayed asleep and what average power it drew while it
#                                       was -- the number that says whether the machine really went down
#   sudo lid_sleep wakeups [status|off|on] [inputs|pcie|all]
#                                       which devices may wake the machine.  An input event arriving as
#                                       the suspend enters aborts it ("Wakeup pending. Abort CPU freeze"),
#                                       so 'off' disarms the four hid-over-i2c devices and leaves the power
#                                       button and the lid (gpio-keys) armed.  Runtime only: a reboot
#                                       puts them all back.
#
# What the logs already say (boot ids 20167034, 3a63a313, 2026-09-17):
#
#   * The lid is a real switch and logind does see it -- `gpio-keys` (event0) carries SW_LID from the
#     device tree's `switch-lid` node, and logind logs `Lid closed.` / `Lid opened.` -- so "closing the
#     lid does nothing" is not a missing-lid problem.
#   * logind then suspends, and the FIRST suspend of a boot really sleeps (no failure line, exit only
#     on resume -- 19 and 88 minutes in the two boots above).
#   * Every suspend after that first one aborts within ~1 s, and systemd-logind retries it every ~33 s
#     for as long as the lid stays shut:
#
#       logind : Suspending...                       14:43:19
#       kernel : PM: suspend entry (deep)            14:43:21
#       kernel : xhci-hcd xhci-hcd.1.auto: PM: dpm_run_callback(): platform_pm_suspend returns -22
#       kernel : xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
#       kernel : PM: Some devices failed to suspend, or early wake event detected
#       kernel : PM: suspend exit  ... then the same again as s2idle, same device, same -22
#       logind : Operation 'suspend' finished.       14:43:22   (3 s later; repeat at 14:43:52, 14:44:25...)
#
#     -22 is EINVAL from xhci_suspend() (drivers/usb/host/xhci.c):
#         if (hcd->state != HC_STATE_SUSPENDED || (xhci->shared_hcd && ...)) return -EINVAL;
#     i.e. at platform-suspend time the USB core had not left the HCD in the suspended state, so the
#     controller refuses and the whole suspend aborts.  A closed lid therefore leaves the machine
#     running: fans on, ~6-7 W idle, about 10 %/h of the battery, and the Wi-Fi firmware failure of
#     docs/wifi.md lands on the one suspend that does happen.
#
# test mode suspends for real; wake it with the lid, the power button or a key, then read the verdict.
set -u

MODE="${1:-status}"
ARG="${2:-}"
N="${2:-1}"
LOG="${A16_LOG:-/home/jc/a16-payload/sleep-test-$(date +%Y%m%d-%H%M%S).log}"
CONF="${A16_LID_CONF:-/etc/systemd/logind.conf.d/50-a16-lid.conf}"
SKIP_ROOT="${A16_SKIP_ROOT:-0}"

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }

usage() {
  cat <<'EOF'
lid_sleep -- what a closed lid does, whether this machine can suspend, and what stops it.

usage:
  lid_sleep --help            this text
  lid_sleep status            read-only, no root: mem_sleep, the logind lid policy and its lid lines,
                              this boot's suspend attempts, the device that aborted them, USB wakeups
  sudo lid_sleep test [n]     suspend n times (default 1), and report after each attempt whether the
                              machine slept, with the kernel lines and the device that stopped it
  sudo lid_sleep lid ignore   write HandleLidSwitch=ignore -- a closed lid does nothing (this stops the
                              ~33 s retry loop; it does not create sleep)
  sudo lid_sleep lid suspend  write HandleLidSwitch=suspend -- the systemd default

the choice this gives you: a closed lid can sleep exactly once per boot, and that one suspend is what
kills the Wi-Fi firmware on resume (the radio then needs a reboot).  'lid ignore' keeps the radio and
gives up the sleep.  Pick per day:  sudo lid_sleep lid ignore   /   sudo lid_sleep lid suspend

what the evidence says (boots 20167034, 3a63a313, e090779e):
  the first suspend of a boot sleeps; every later one aborts within a second at xhci-hcd.1.auto
  (-EINVAL from xhci_suspend(), hcd->state != HC_STATE_SUSPENDED) and systemd-logind retries it every
  ~33 s while the lid is shut, so a closed lid leaves the machine awake at ~6-7 W (~10 %/h).
  `lid_sleep test 2` reproduces exactly that: first attempt sleeps, second aborts.
  Wi-Fi may be dead after the attempt that slept -- that is `reload_wifi`.

log: ~/a16-payload/sleep-test-<timestamp>.log
env: A16_LID_CONF (where `lid` writes its file), A16_LOG, A16_SKIP_ROOT=1 (skip the root check).
EOF
}

# --help before anything else: no log file, no root check.
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

lid_device() {   # the input device carrying SW_LID, if any
  local d
  for d in /sys/class/input/event*; do
    [ "$(cat "$d/device/capabilities/sw" 2>/dev/null)" = 1 ] && { printf '%s (%s)' "$(basename "$d")" "$(cat "$d/device/name" 2>/dev/null)"; return 0; }
  done
  printf 'none'
}
lid_switch_bit() { cat /sys/devices/platform/gpio-keys/device/capabilities/sw 2>/dev/null; }
hcd_state()      { cat /sys/kernel/debug/usb/xhci-hcd.1.auto/state 2>/dev/null; }
usb_devices() {  # one line per USB device: name, driver, wakeup flag
  local d
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    printf '   %-14s %s:%s  driver=%-14s wakeup=%s\n' "$(basename "$d")" \
      "$(cat "$d/idVendor" 2>/dev/null)" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)" \
      "$(cat "$d/power/wakeup" 2>/dev/null)"
  done
}

show_state() {
  rule
  say "-- power"
  say "   /sys/power/state      : $(tr '\n' ' ' < /sys/power/state 2>/dev/null)"
  say "   /sys/power/mem_sleep  : $(cat /sys/power/mem_sleep 2>/dev/null)   [(bracketed = what a suspend uses)]"
  say "   logind HandleLidSwitch: $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | cut -d'"' -f2)"
  say "   config file           : $CONF $( [ -f "$CONF" ] && cat "$CONF" | tr '\n' ' ' || echo '(absent -- systemd default applies)')"
  rule
  say "-- the lid switch"
  say "   SW_LID on            : $(lid_device)"
  say "   device tree node     : label=$(tr -d '\0' < /proc/device-tree/gpio-keys/switch-lid/label 2>/dev/null)  gpios: $(od -An -tx4 /proc/device-tree/gpio-keys/switch-lid/gpios 2>/dev/null | tr -s ' ' | sed 's/^ //')"
  say "   logind on this boot  :"
  journalctl -b --no-pager -o short-iso 2>/dev/null | grep -E 'logind.*(Lid (closed|opened)|Suspending|Operation .suspend. finished)' | tail -8 | sed 's/^/      /'
  say "   [(no lines above = logind has not seen the lid change state in this boot)]"
  rule
  say "-- suspend attempts and what stopped them"
  say "   attempts this boot   : $(journalctl -b --no-pager -o cat 2>/dev/null | grep -c 'suspend entry')"
  journalctl -k -b --no-pager -o short-iso 2>/dev/null \
    | grep -E 'PM: suspend (entry|exit)|failed to suspend async|Some devices failed|failed to resume|A16 ' | tail -14 | sed 's/^/      /'
  rule
  say "-- USB: the controller the abort names, and what is on it"
  say "   xhci-hcd.1.auto (usb@a400000) state: $(hcd_state)   [no debugfs/usb => not readable]"
  say "   xhci_plat_hcd srcversion: $(cat /sys/module/xhci_plat_hcd/srcversion 2>/dev/null)"
  say "   the suspend fix (a16 module params): skip_unsuspended_hcd=$(cat /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd 2>/dev/null || echo 'n/a') state_log=$(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log 2>/dev/null || echo 'n/a')"
  say "   ['n/a' = the stock xhci-plat-hcd.ko is loaded;  sudo bash ~/a16.sh suspendfix  installs the patched one]"
  usb_devices
  say "   [(wakeup=enabled on a device is what keeps a controller from being suspended on some paths;"
  say "     the abort at -22 comes from the controller itself, see the header of this script)]"
  rule
  say "-- what a closed lid costs (measured 2026-09-17, boot e090779e)"
  say "   the first suspend of a boot sleeps, and its resume kills the Wi-Fi firmware:"
  say "      ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110"
  say "      -> then 'wmi command 16387 timeout' for the rest of the boot, and the interface cannot come up"
  say "   after that the radio does not come back without a reboot: restarting NetworkManager and"
  say "   wpa_supplicant does nothing, and the driver-teardown rungs hang the machine (the module unload"
  say "   froze it and needed a hard reset).  See docs/wifi.md."
  say "   While that stands, a closed lid costs the radio:   sudo lid_sleep lid ignore"
  rule
  say "-- wakeup sources that have fired in this boot"
  local w
  for w in /sys/class/wakeup/wakeup*/; do
    [ "$(cat "$w/event_count" 2>/dev/null)" -gt 0 ] 2>/dev/null && \
      printf '   %-12s %-40s events=%s\n' "$(basename "$w")" "$(cat "$w/name" 2>/dev/null)" "$(cat "$w/event_count" 2>/dev/null)"
  done
}

do_test() {
  rule
  say "-- suspending now ($N attempt(s), 5 s apart).  Wake the machine with the lid, the power button or a key."
  say "   If an attempt aborts you will see it return in about a second, with the reason below it."
  local i=1
  while [ "$i" -le "$N" ]; do
    local mark u0 u1 d0 d1
    mark=$(date '+%Y-%m-%d %H:%M:%S')
    u0=$(awk '{printf "%d", $1}' /proc/uptime); d0=$(date +%s)
    say ""
    say "   --- attempt $i  (started $mark) ---"
    systemctl suspend 2>&1 | sed 's/^/      /'
    u1=$(awk '{printf "%d", $1}' /proc/uptime); d1=$(date +%s)
    local slept=$((u1-u0)); wall=$((d1-d0))
    [ "$slept" -lt 0 ] && slept=0
    say "      systemctl returned after ${wall}s; uptime advanced ${slept}s"
    say "      (the clock stops while suspended, and systemctl returns as soon as logind accepts the"
    say "       request -- neither number says whether the machine slept.  The journal below does.)"
    say "      kernel says:"
    journalctl -k --since "$mark" --no-pager -o short-iso 2>/dev/null \
      | grep -E 'PM: suspend (entry|exit)|failed to suspend async|Some devices failed|failed to resume|dpm_run_callback|A16 ' \
      | sed 's/^/         /'
    # The verdict comes from the journal, never from uptime.  Measured 2026-10-02 21:34: a real 7 s
    # s2idle suspend (entry 21:34:52, exit 21:34:59) sat under an uptime delta of 0, and the old logic
    # reported "returned immediately without sleeping" for a suspend that plainly happened.
    local win n_entry n_exit t_entry t_exit secs dev
    win=$(journalctl -k --since "$mark" --no-pager -o short-iso 2>/dev/null)
    n_entry=$(printf '%s\n' "$win" | grep -c 'PM: suspend entry')
    n_exit=$(printf '%s\n' "$win" | grep -c 'PM: suspend exit')
    t_entry=$(printf '%s\n' "$win" | grep -m1 'PM: suspend entry' | awk '{print $1}')
    t_exit=$(printf '%s\n' "$win" | grep 'PM: suspend exit' | tail -1 | awk '{print $1}')
    if printf '%s\n' "$win" | grep -qE 'Some devices failed to suspend|failed to suspend async'; then
      local dev
      dev=$(printf '%s\n' "$win" | grep -oE '[a-z0-9.-]+: PM: failed to suspend' | head -1)
      say "      VERDICT: did NOT sleep -- the suspend aborted (${dev:-device not named}).  This is the -22"
      say "               controller case in the header; nothing below userspace can talk it round."
    elif [ "$n_entry" -gt 0 ] && [ "$n_exit" -gt 0 ]; then
      secs=$(( $(date -d "${t_exit%-*}" +%s 2>/dev/null || echo 0) - $(date -d "${t_entry%-*}" +%s 2>/dev/null || echo 0) ))
      say "      VERDICT: slept.  ${t_entry} -> ${t_exit}   (${secs}s)"
      say "               if the panel needed a gdm restart to come back, that was the resume hook doing"
      say "               its job:  journalctl -t a16-display-wake"
    elif [ "$n_entry" -gt 0 ]; then
      say "      VERDICT: it went to sleep and has written no 'PM: suspend exit' in this window."
      say "               If you are reading this then something did wake it:  sudo bash ~/a16.sh resume_log"
    else
      say "      VERDICT: no suspend was recorded at all in this window -- the request was refused, or it"
      say "               woke before a line could be written.  A blanked screen is NOT a suspend."
    fi
    i=$((i+1))
    [ "$i" -le "$N" ] && { say ""; say "   next attempt in 5 s (the second one is the interesting one)"; sleep 5; }
  done
  rule
  say "How to read the pair of attempts: the old pattern was 'the first suspend of a boot sleeps, every"
  say "later one aborts at xhci-hcd.1.auto with -22'.  The patched xhci-plat-hcd (patches/0010) is the"
  say "loaded module now, so that abort should be gone; if a later attempt still aborts there, the patched"
  say "module is not the one that loaded (check with:  sudo bash ~/a16.sh wifisleep)."
  say "After an attempt that slept, the radio should survive it (a16_keep_mhi_up=Y).  Confirm with:"
  say "    sudo reload_wifi status      (and plain 'sudo reload_wifi' for the soft rungs if it did not)"
}

do_lid() {
  local want="$ARG"
  case "$want" in
    ignore|suspend) ;;
    *) say "usage: bash $0 lid ignore|suspend   (a closed lid does nothing / suspends)"; exit 2 ;;
  esac
  rule
  say "-- setting HandleLidSwitch=$want in $CONF"
  mkdir -p "$(dirname "$CONF")" || exit 1
  { printf '# written by a16-sleep-test.sh -- what a closed lid does.\n# ignore: the lid is inert (the machine cannot suspend more than once per boot anyway).\n# suspend: systemd default; logind retries every ~33 s while the lid is shut.\n[Login]\nHandleLidSwitch=%s\nHandleLidSwitchExternalPower=%s\n' "$want" "$want"; } > "$CONF" || exit 1
  say "   written: $(tr '\n' ' ' < "$CONF")"
  local before rc after
  before=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | cut -d'"' -f2)
  rc=0
  local out
  out=$(systemctl reload systemd-logind 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/   /'
  say "   'systemctl reload systemd-logind' exited $rc (a reload does not drop sessions)"
  after=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | cut -d'"' -f2)
  if [ "$after" = "$want" ]; then
    say "   effective now: HandleLidSwitch=$after  (was $before)"
  else
    say "   effective now: HandleLidSwitch=$after -- unchanged (was $before).  Apply it with:"
    say "      sudo systemctl restart systemd-logind      (a restart can end logged-in sessions;"
    say "      a reboot also applies it, and the file is already in place)"
  fi
  say "   [ignore stops the 33-second retry loop while the lid is shut.  It does not create sleep: only a"
  say "    working suspend does, and the suspend that works is the first one of a boot.]"
}

CMD=$(basename "$0"); case "$CMD" in reload_wifi|lid_sleep) ;; *) CMD=lid_sleep ;; esac
say "=== $CMD  (a16-sleep-test.sh)  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE${ARG:+ $ARG} ==="
say "kernel: $(uname -r)   boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "log   : $LOG"

case "$MODE" in
  status) show_state ;;
  test)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo lid_sleep test $N"; say ""; exit 1; }
    case "$N" in ''|*[!0-9]*) say "usage: bash $0 test [count]"; exit 2 ;; esac
    show_state
    do_test ;;
  lid)
    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo lid_sleep lid $ARG"; say ""; exit 1; }
    do_lid ;;
  debug)
    # A resume that never completes leaves nothing behind on this platform: no ramoops/pstore backend,
    # no /dev/watchdog, both lockup detectors off -- the journal just stops at "PM: suspend entry".
    # So the only capture is live: no_console_suspend keeps the kernel printing through the suspend and
    # the resume (with consoleblank=0 those messages land on the panel), initcall_debug names each
    # device callback being resumed, and pm_debug_messages prints the PM steps themselves.  Spend a boot
    # on it, then 'debug off'.
    [ "$(id -u)" = 0 ] || [ "${SKIP_ROOT:-0}" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh sleep debug"; say ""; exit 1; }
    ENTRY=/home/jc/A16Build/BRINGUP/tools/a16-drm-debug-entry.sh
    case "${ARG:-on}" in
      off|remove|revert)
        A16_PARAMS="drm.debug=0x1ff consoleblank=0 no_console_suspend ignore_loglevel initcall_debug pm_debug_messages" bash "$ENTRY" remove inline ;;
      shutdown)
        # For the other brown-screen bug: a shutdown/reboot that reaches systemd-shutdown and then never
        # completes.  With initcall_debug the kernel names every device as device_shutdown() walks them
        # (drivers/base/core.c: dev_info(dev, "shutdown\n")), so the last name on the panel is the one
        # that hangs.  No drm.debug here on purpose -- the console has to stay readable.
        A16_PARAMS="initcall_debug ignore_loglevel consoleblank=0" bash "$ENTRY" arm
        say ""
        say "-- next: reboot (that row is the menu default), then shut down (or reboot) and WATCH THE PANEL.  The last device"
        say "   name printed before it stops is the one that hangs.  Write it down -- there is no"
        say "   post-mortem on this platform, the console is the record.  Remove with:"
        say "   sudo bash ~/a16.sh sleep debug off" ;;
      *)
        # No drm.debug here on purpose: this test is read off the panel, and DRM category
        # logging would flood the console and bury the last PM line printed before a stall.
        A16_PARAMS="consoleblank=0 no_console_suspend ignore_loglevel initcall_debug pm_debug_messages" bash "$ENTRY" arm
        say ""
        say "-- next: reboot and pick the row the tool named (the linux-next t2 row); it is still the"
        say "   menu default, so an unattended boot lands on it.  Then suspend ('sudo bash ~/a16.sh"
        say "   sleep test 1' or just close the lid).  No monitor, so nothing else is in the picture."
        say "   if it does not come back: the panel carries the last PM/device lines printed, and that is"
        say "   the stall point -- write down the last line or photograph it."
        say "   afterwards:  sudo bash ~/a16.sh sleep debug off" ;;
    esac ;;
  measure)
    # "Is it down?" cannot be answered by listening to the fans -- the EC keeps a floor (1980/1320 RPM at
    # 34 °C on this machine).  It is answered by two numbers: how long the sleep lasted, and how much
    # energy the battery lost while it lasted.  Both are recorded here, and the before-state is written
    # to the log BEFORE the suspend, so even a hard reset leaves it behind.
    [ "$(id -u)" = 0 ] || [ "${SKIP_ROOT:-0}" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh sleep measure"; say ""; exit 1; }

    fans_line() {
      local h
      for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "asus_glymur_ec" ] || continue
        printf 'fan1=%s fan2=%s temp1=%s temp2=%s' \
          "$(cat "$h/fan1_input" 2>/dev/null)" "$(cat "$h/fan2_input" 2>/dev/null)" \
          "$(cat "$h/temp1_input" 2>/dev/null)" "$(cat "$h/temp2_input" 2>/dev/null)"
        return 0
      done
      printf '(EC hwmon not present)'
    }

    # NOTE: no 'local' in this branch -- it is the main script body, not a function.  The first two
    # measurement runs died with "local: can only be used in a function" / "BAT: unbound variable"
    # before they reported anything (2026-10-02 22:09 and 22:13), so the variables are plain here.
    BAT=/sys/class/power_supply/qcom-battmgr-bat
    mode=""; e0=""; e1=""; t0=""; t1=""; tj0=""; tj1=""; secs=0; wh=""; w=""; v=""
    mode=$(tr ' ' '\n' < /sys/power/mem_sleep 2>/dev/null | sed -n 's/^\[\(.*\)\]$/\1/p')
    e0=$(cat "$BAT/energy_now" 2>/dev/null); t0=$(date +%s)
    rule
    say "-- sleep measurement   (boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null))"
    say "   mode           : ${mode:-?}      (mem_sleep = $(tr '\n' ' ' < /sys/power/mem_sleep))"
    say "   battery before : ${e0:-?} uWh     ac_online=$(cat /sys/class/power_supply/qcom-battmgr-ac/online 2>/dev/null)"
    say "   EC before      : $(fans_line)"
    say "   log            : $LOG   (written now, so a hard reset cannot lose the before-state)"
    say ""
    say "   suspending now.  Wake it with the lid, a key or the power button, and let it sleep at least"
    say "   a minute if you can -- a one-second sleep proves nothing."
    if [ "${A16_DRY:-0}" = 1 ]; then
      say "   (A16_DRY=1: not suspending -- this run only exercises the recording and the report)"
    else
      systemctl suspend 2>&1 | sed 's/^/      /'
    fi
    # `systemctl suspend` can return as soon as logind accepts the request, so wait for the resume to be
    # on record before reading the after-state.
    i=0
    while [ "$i" -lt 30 ]; do
      journalctl -k --since "$(date -d "@$t0" '+%Y-%m-%d %H:%M:%S')" --no-pager -o cat 2>/dev/null \
        | grep -q 'PM: suspend exit' && break
      sleep 1; i=$((i+1))
    done
    t1=$(date +%s); e1=$(cat "$BAT/energy_now" 2>/dev/null)
    win=$(journalctl -k --since "$(date -d "@$t0" '+%Y-%m-%d %H:%M:%S')" --no-pager -o short-iso 2>/dev/null)
    tj0=$(printf '%s\n' "$win" | grep -m1 'PM: suspend entry' | awk '{print $1}')
    tj1=$(printf '%s\n' "$win" | grep 'PM: suspend exit' | tail -1 | awk '{print $1}')
    secs=$((t1-t0))
    [ -n "$tj0" ] && [ -n "$tj1" ] && \
      secs=$(( $(date -d "${tj1%-*}" +%s 2>/dev/null || echo 0) - $(date -d "${tj0%-*}" +%s 2>/dev/null || echo 0) ))
    [ "$secs" -lt 0 ] && secs=0
    say ""
    say "-- result"
    say "   journal        : ${tj0:-no entry line} -> ${tj1:-NO EXIT LINE}   (${secs}s)"
    say "   battery after  : ${e1:-?} uWh"
    say "   EC after       : $(fans_line)"
    wh=""; w=""
    if [ -n "$e0" ] && [ -n "$e1" ] && [ "$secs" -gt 0 ]; then
      wh=$(awk -v a="$e0" -v b="$e1" 'BEGIN{printf "%.4f", (a-b)/1e6}')
      w=$(awk -v a="$e0" -v b="$e1" -v s="$secs" 'BEGIN{printf "%.2f", ((a-b)/1e6)/(s/3600)}')
      say "   energy used    : ${wh} Wh over ${secs}s   =>   ${w} W average"
    fi
    # The verdict order matters: "no suspend at all" must never be read as "powered down" (a dry run with
    # an unmoving gauge produced exactly that on 2026-10-02 22:25), and neither must an 8-second sleep
    # (22:33:57-22:34:05, aborted by a pending wakeup -- reported as "it really powered down" because the
    # bar was only 5 s).  A power verdict needs a sleep long enough to mean something.
    if [ -z "$tj0" ]; then
      v=none
    elif [ -z "$tj1" ]; then
      v=noexit
    elif [ "$secs" -lt 60 ]; then
      v=short
    else
      v=stayed
    fi
    case "$v" in
      none)    say "   VERDICT: no suspend was recorded in this window -- nothing slept (a dry run, or the"
               say "            request was refused).  This says nothing about power." ;;
      noexit)  say "   VERDICT: it went to sleep and wrote no exit line -- either it never came back (a hard"
               say "            reset would explain that) or the resume went unrecorded." ;;
      short)   say "   VERDICT: it did not stay asleep (${secs}s).  A sleep this short cannot say anything"
               say "            about power -- look for 'Wakeup pending. Abort CPU freeze' in the journal"
               say "            (an armed wakeup source received an event during the suspend: check"
               say "            'sudo bash ~/a16.sh sleep wakeups status')." ;;
      stayed)  say "   VERDICT: it stayed asleep for ${secs}s -- that is the answer to 'did it sleep'."
               say "            For 'did it go DOWN', read the EC line above: if temp1/temp2 fell and the fans"
               say "            stopped, the SoC powered off while it slept.  The battery gauge cannot answer"
               say "            that on this machine: at 22:38 it read 53440000 uWh and five minutes later,"
               say "            unplugged with power_now 0 W, it read 53573000 uWh -- it rose." ;;
      short)   say "   VERDICT: it did not stay asleep (${secs}s) -- something woke it immediately.  The wakeup" 
               say "            sources below are the place to look." ;;
    esac
    say ""
    say "-- what can wake it (top wakeup sources; root-only file)"
    if [ -r /sys/kernel/debug/wakeup_sources ]; then
      { head -1 /sys/kernel/debug/wakeup_sources; sort -k3 -nr /sys/kernel/debug/wakeup_sources | head -8; } \
        | sed 's/^/   /' | tee -a "$LOG"
    else
      say "   /sys/kernel/debug/wakeup_sources is not readable -- needs root (this tool is running as"
      say "   $(id -un)$([ "$(id -u)" != 0 ] && echo ' -- re-run with sudo'))"
    fi
    say "   last wakeup IRQ: $(cat /sys/power/pm_wakeup_irq 2>/dev/null)   (identify it: grep -E '^ *<n>:' /proc/interrupts)" ;;
  wakeups)
    # 2026-10-02: a suspend attempt aborted itself with "Wakeup pending. Abort CPU freeze", and the
    # wakeup_sources list showed the four hid-over-i2c devices (touchpad@15, keyboard@15, touchscreen@10,
    # hid@17) all wakeup-armed.  Nothing had *caused* a wakeup (wakeup_count 0 everywhere) -- a pending
    # input event during suspend entry is enough to abort it, which is what made attempts come back in a
    # second or two while keys were being pressed.  This toggles that, and nothing else.
    [ "$(id -u)" = 0 ] || [ "${SKIP_ROOT:-0}" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh sleep wakeups ${ARG:-status}"; say ""; exit 1; }
    WA_ACTION="${ARG:-status}"
    WA_GROUP="${3:-inputs}"
    wa_label() {   # a readable name for a wakeup file: PCI devices by address, others by device-tree node
      local f="$1" d n
      d=$(dirname "$(dirname "$f")")
      case "$d" in
        */bus/pci/devices/*) basename "$d" ;;
        *) n=$(basename "$(readlink -f "$d/of_node" 2>/dev/null)" 2>/dev/null)
           if [ -n "$n" ]; then echo "$n"; else basename "$d"; fi ;;
      esac
    }
    wa_list() {
      local g="$1" d n
      case "$g" in
        inputs) g="touchpad touchscreen keyboard hid" ;;
        pcie)   g="root-port" ;;
        ports)  # the PCI BRIDGES only -- the root ports, not every PCI function
          for d in /sys/bus/pci/devices/*/power/wakeup; do
            [ -r "$d" ] || continue
            case "$(cat "$(dirname "$(dirname "$d")")/class" 2>/dev/null)" in
              0x0604*) echo "$d" ;;
            esac
          done
          return ;;
        all)    g="touchpad touchscreen keyboard hid root-port" ;;
      esac
      if [ "$g" = "root-port" ]; then
        for d in /sys/bus/pci/devices/*/power/wakeup; do
          [ -r "$d" ] || continue
          echo "$d"
        done
        return
      fi
      for d in /sys/bus/i2c/devices/*/power/wakeup; do
        [ -r "$d" ] || continue
        n=$(basename "$(readlink -f "$(dirname "$(dirname "$d")")/of_node" 2>/dev/null)" 2>/dev/null)
        case "$n" in *touchpad*|*touchscreen*|*keyboard*|*hid*) ;; *) continue ;; esac
        case " $g " in *" ${n%%@*} "*) echo "$d" ;; esac
      done
    }
    case "$WA_ACTION" in
      status)
        rule
        say "-- what may wake the machine"
        for d in $(wa_list "$WA_GROUP"); do
          printf '   %-22s %s\n' "$(wa_label "$d")" "$(cat "$d" 2>/dev/null)"
        done
        for p in /sys/devices/platform/gpio-keys/power/wakeup; do
          [ -r "$p" ] && printf '   %-22s %s   (the lid and the power button -- leave this armed)\n' "gpio-keys" "$(cat "$p")"
        done
        say ""
        say "   wakeup_sources: $(grep -c . /sys/kernel/debug/wakeup_sources 2>/dev/null || echo '?') sources; the count of who actually woke it is the 4th column"
        ;;
      off|on)
        [ "$WA_ACTION" = off ] && WA_VAL=disabled || WA_VAL=enabled
        for d in $(wa_list "$WA_GROUP"); do
          printf '%s' "$WA_VAL" > "$d" 2>/dev/null \
            && printf '   %-22s -> %s\n' "$(wa_label "$d")" "$(cat "$d" 2>/dev/null)" \
            || printf '   %-22s FAILED (read-only?)\n' "$(wa_label "$d")" | tee -a "$LOG"
        done
        say ""
        say "   runtime only -- a reboot re-arms everything.  The power button and the lid are not touched."
        say "   then test:  sudo bash ~/a16.sh sleep measure   (and do not touch the machine until you"
        say "   wake it with the power button -- a key press during suspend entry aborts the suspend)"
        ;;
      *) say "usage: sudo bash ~/a16.sh sleep wakeups [status|off|on] [inputs|pcie|all]"; exit 2 ;;
    esac ;;
  *) say "usage: lid_sleep [status|test [count]|lid ignore|suspend|debug [off]|measure]   (lid_sleep --help for the full text)"; exit 2 ;;
esac
say ""
say "log: $LOG"
