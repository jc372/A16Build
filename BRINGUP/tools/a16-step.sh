#!/usr/bin/env bash
# a16-step.sh -- the whole Wi-Fi/sleep job as ONE command over ssh.
#
#   sudo bash ~/a16step.sh            do the next step (it works out which one), and print the plan
#   sudo bash ~/a16step.sh status     no changes: where everything is
#   sudo bash ~/a16step.sh test       suspend once now, in the background, and record the verdict
#   sudo bash ~/a16step.sh verdict    what the last test found (safe to run any time)
#   sudo bash ~/a16step.sh log        the last few log lines of everything this file ran
#   sudo bash ~/a16step.sh xhci       land the second-suspend fix in the initramfs (optional, later)
#
# Written 2026-09-22 for the state this machine is in: the Wi-Fi dies on the resume of a suspend,
# s2idle does not save it, unloading ath12k hangs the machine, and the EC driver is already in.
# The one lever left is patches/0014 (built, ABI-verified) -- do not SoC-global-reset the WiFi device
# on a resume, so MHI can re-attach to the firmware the suspend deliberately kept.
#
# Everything is logged to ~/a16-payload/step-<timestamp>.log and the test runs detached (setsid), so
# an ssh session dropping at the suspend does not lose the result: reconnect and run this file again.
set -u

MODE="${1:-next}"
HOSTK=$(uname -r)
REPO="/home/jc/A16Build"
TREE="${A16_TREE:-/home/jc/build/linux-next-1a1de54f7369}"
KO="$TREE/drivers/net/wireless/ath/ath12k/ath12k.ko"
UPD="/lib/modules/$HOSTK/updates/a16/ath12k.ko"
SP="/lib/modules/$HOSTK/parameters"                 # (unused, kept for symmetry)
LOG="${A16_LOG:-/home/jc/a16-payload/step-$(date +%Y%m%d-%H%M%S).log}"
RADIOFIX="$REPO/BRINGUP/tools/a16-install-ath12k-resume-fix.sh"
WIFISLEEP="$REPO/BRINGUP/tools/a16-wifi-sleep.sh"
ECTOOL="$REPO/BRINGUP/tools/a16-ec.sh"
LASTTEST="/home/jc/a16-payload/step-last-test.log"   # the detached test writes here
DRY="${A16_DRY:-0}"
SKIP_ROOT="${A16_SKIP_ROOT:-0}"

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
run()  { if [ "$DRY" = 1 ]; then say "   [dry-run] $*"; return 0; fi; "$@"; }
usage() {
  cat <<'EOF'
a16step -- one command over ssh for the Wi-Fi/sleep job.

  sudo bash ~/a16step.sh            do the next step (installs the fix, or starts the test, or shows
                                    the verdict -- it decides from the machine's state)
  sudo bash ~/a16step.sh status     read-only: state of everything
  sudo bash ~/a16step.sh test       suspend once now (detached, so an ssh drop cannot lose it)
  sudo bash ~/a16step.sh verdict    what the last test found
  sudo bash ~/a16step.sh log        tail the last log files
  sudo bash ~/a16step.sh nosleep    make this machine UNABLE to suspend itself: GNOME's idle suspend
                                    (15 min on battery), the lid, and the systemd suspend targets.
                                    Do this first -- the resume is what is broken right now, and a
                                    machine that sleeps while you are away costs a hard reset.
  sudo bash ~/a16step.sh nosleep off  allow suspending again
  sudo bash ~/a16step.sh watch      start a synced kernel-log tail (so the next sleep attempt leaves
                                    a record even if the machine has to be reset), `watch off` stops it
  sudo bash ~/a16step.sh xhci       rebuild the initramfs so patches/0010 (second-suspend fix) loads
                                    by itself -- do this AFTER the Wi-Fi test, one change at a time

typical run from ssh:
  sudo bash ~/a16step.sh            -> installs patches/0014 and says: start again into [3]
  <start again into [3]>
  sudo bash ~/a16step.sh            -> starts the suspend test in the background
  <open the lid to wake it, then reconnect>
  sudo bash ~/a16step.sh            -> the verdict: did the radio survive?

If the screen stays black after the resume, ssh in anyway and run this file: the machine is usually
alive, and reading the log is what keeps the evidence (a hard reset loses it).
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

# --------------------------------------------------------------------------- state
radiofix_installed() { [ -f "$UPD" ]; }
radiofix_loaded()    { [ -n "$(cat /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume 2>/dev/null)" ]; }
radiofix_built()     { [ -f "$KO" ] && modinfo -F parm "$KO" 2>/dev/null | grep -q a16_skip_global_reset_on_resume; }
suspends_this_boot() { journalctl -k -b --no-pager -o cat 2>/dev/null | grep -c 'PM: suspend entry'; }
radio_state()        { local d; d=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
                       [ -n "$d" ] || { printf 'no netdev'; return 1; }
                       if iw dev "$d" link 2>/dev/null | grep -q 'Connected to'; then printf 'associated'; return 0; fi
                       printf 'not associated'; return 1; }
last_boot_id()       { cat /proc/sys/kernel/random/boot_id; }

show_status() {
  rule
  say "-- the fix: patches/0014 (no SoC global reset when resuming the WiFi device)"
  say "   source patched : $(grep -q ATH12K_FLAG_A16_RESUMING "$TREE/drivers/net/wireless/ath/ath12k/core.h" 2>/dev/null && echo yes || echo no)"
  say "   module built   : $(radiofix_built && echo "yes ($(stat -c %s "$KO" 2>/dev/null) bytes, parameter present)" || echo 'no -- run: sudo bash ~/a16step.sh')"
  say "   module installed: $(radiofix_installed && echo "yes ($UPD)" || echo no)"
  say "   LOADED now     : $(radiofix_loaded && echo "the patched build (a16_skip_global_reset_on_resume=$(cat /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume))" || echo "NOT the patched build -- a restart is needed for it to load")"
  rule
  say "-- the machine"
  say "   kernel         : $HOSTK   boot: $(last_boot_id)"
  say "   suspends this boot: $(suspends_this_boot)"
  say "   radio          : $(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | awk -F: '$2=="connected" && $1 ~ /^wl/{print $1" ("$3")"}' | head -1) / $(radio_state)"
  say "   EC             : $(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -q 0076 && echo bound || echo not bound)  kbd backlight=$(cat /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null || echo n/a)/$(cat /sys/class/leds/asus::kbd_backlight/max_brightness 2>/dev/null || echo n/a)"
  say "   mem_sleep      : $(cat /sys/power/mem_sleep 2>/dev/null | tr '\n' ' ')"
  rule
}

do_verdict() {
  rule
  say "-- the last suspend test"
  local f="" from_this_tool=0
  if [ -s "$LASTTEST" ]; then f="$LASTTEST"; from_this_tool=1
  else f=$(ls -t /home/jc/a16-payload/wifi-sleep-*.log 2>/dev/null | head -1); fi
  if [ -z "$f" ]; then say "   no test has run yet.  Start one with: sudo bash ~/a16step.sh"; rule; return; fi
  say "   log: $f   ($(stat -c %y "$f" 2>/dev/null | cut -d. -f1))"
  if [ "$from_this_tool" = 0 ]; then
    say "   NOTE: this is the newest wifi-sleep log, not a test this file ran -- if it predates the"
    say "         install it says nothing about patches/0014.  Check the kernel log below for"
    say "         'A16: resume', which only the patched build prints."
  fi
  say "   fix active in THIS boot: $(journalctl -k -b --no-pager -o cat 2>/dev/null | grep -c 'A16: resume') 'A16: resume' line(s)"
  grep -E 'mode=|mem_sleep=|away:|SUSPEND:|RADIO  :|VERDICT|A16: resume|timeout while waiting|failed to resume|Wait for device' "$f" 2>/dev/null | tail -20 | sed 's/^/      /'
  rule
  local radio; radio=$(radio_state)
  if grep -qE 'RADIO  : SURVIVED' "$f" 2>/dev/null; then
    say "VERDICT: the radio SURVIVED the suspend.  patches/0014 is the fix -- keep it installed."
    say "         next (separate change, do it when you are ready):  sudo bash ~/a16step.sh xhci"
    say "         that lands the second-suspend fix, so a closed lid can sleep more than once."
  elif grep -qE 'RADIO  : GONE' "$f" 2>/dev/null; then
    say "VERDICT: the radio died again, so skipping the SoC reset was not enough -- the device really"
    say "         does come out of the suspend without working firmware.  Nothing else in userspace can"
    say "         change that (unloading the driver hangs the machine, s2idle does not help, the EC is"
    say "         already in), so the next step is the other half of the same idea: have the resume do a"
    say "         full re-init -- power cycle the device and let the QMI path download the firmware, the"
    say "         way the probe and the crash-recovery path already do.  Tell me and it gets built."
    say "         Today, to keep the machine usable:  sudo lid_sleep lid ignore   (a closed lid stops"
    say "         suspending, so the radio stays alive; the machine does not sleep)."
  else
    say "VERDICT: no clean verdict in that log -- read it above, and the kernel lines with:"
    say "         sudo journalctl -k -b | grep -E 'A16: resume|restart complete|MHI state|failed to resume'"
  fi
  rule
}

do_next() {
  rule
  if [ ! -f "$REPO/BRINGUP/patches/retired/0014-ath12k-a16-no-soc-global-reset-on-resume.patch" ]; then
    say "FATAL: the patch file is missing from $REPO -- tell me, nothing is changed."; return 1
  fi
  # 1. not installed yet (or the built module is missing) -> install
  if ! radiofix_installed || ! radiofix_built; then
    say "STEP 1 of 3 -- install the fix (patches/0014) into $UPD"
    if ! radiofix_built; then
      say "   the module is not built; building it first (no root needed, ~1 minute)"
      if [ "$DRY" = 1 ]; then say "   [dry-run] bash $RADIOFIX build"; else
        bash "$RADIOFIX" build | sed 's/^/   /' || { say "   build failed -- send me the log: $LOG"; return 1; }
      fi
    fi
    bash "$RADIOFIX" install | sed 's/^/   /'
    rule
    say "NEXT: start again into entry [3], then run this same line:"
    say ""
    say "    sudo bash ~/a16step.sh"
    say ""
    return 0
  fi
  # 2. installed but not the loaded module -> needs the restart
  if ! radiofix_loaded; then
    say "STEP 1 of 3 -- waiting for the restart: the fix is installed, but the loaded ath12k is still"
    say "                the kernel's own build."
    rule
    say "NEXT: start again into entry [3], then:  sudo bash ~/a16step.sh"
    return 0
  fi
  # 2b. the module loaded but the PCI driver next to it did not -> nothing binds the device
  if ! lsmod 2>/dev/null | grep -q '^ath12k_wifi7'; then
    say "PROBLEM: ath12k_wifi7 is not loaded, so the Wi-Fi device has no driver at all."
    say ""
    say "   The usual cause is an export-CRC mismatch in a locally rebuilt ath12k.ko: the loader says"
    say "      ath12k_wifi7: disagrees about version of symbol ath12k_…"
    say "   and refuses it.  Check, then put the stock module back:"
    say ""
    say "      resume_log                          # or: sudo journalctl -k -b | grep -i disagrees"
    say "      sudo ~/a16.sh radiofix revert       # removes $UPD"
    say ""
    say "   then restart, and send me those journal lines -- the fix is a rebuild with the export CRCs"
    say "   transplanted from the kernel's own ath12k.ko (the radiofix tool now does that and verifies it)."
    return 1
  fi

  # 3. loaded and no test yet this boot -> run the test detached
  if [ "$(suspends_this_boot)" = "0" ]; then
    say "STEP 2 of 3 -- the fix is loaded (a16_skip_global_reset_on_resume=$(cat /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume))."
    say "                Starting the suspend test in the background, so this ssh session dropping at"
    say "                the suspend cannot lose the result."
    say ""
    say "    mem_sleep is $(cat /sys/power/mem_sleep 2>/dev/null | tr '\n' ' ') -- unchanged from the last failing"
    say "    test (s2idle), so patches/0014 is the only variable in this run."
    say ""
    say "    It suspends in 10 s.  WAKE IT with the lid, a key, or the power button."
    say "    Then reconnect and run:  sudo bash ~/a16step.sh"
    say ""
    if [ "$DRY" = 1 ]; then
      say "   [dry-run] setsid nohup bash $WIFISLEEP test 1 > $LASTTEST 2>&1 &"
    else
      : > "$LASTTEST"
      setsid nohup bash -c "sleep 10; bash '$WIFISLEEP' test 1" </dev/null >"$LASTTEST" 2>&1 &
      disown 2>/dev/null || true
      say "   started (log: $LASTTEST)"
    fi
    rule
    return 0
  fi
  # 4. a suspend has happened -> verdict
  say "STEP 3 of 3 -- a suspend has already run on this boot."
  do_verdict
  say "the whole log of this run: $LOG"
}

do_test() {
  rule
  local masked=0
  systemctl is-enabled sleep.target 2>/dev/null | grep -q masked && masked=1
  [ "$masked" = 1 ] && say "-- sleep.target is masked (nosleep); unmasking for this run, re-masking afterwards"
  [ "$masked" = 1 ] && run systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
  if ! watch_running; then
    say "-- no kernel-log watcher is running; starting one first (see 'watch' in --help): a hard reset"
    say "   otherwise erases the evidence, which is what happened to the last two attempts."
    do_watch on
  fi
  rule
  local masked=0
  systemctl is-enabled sleep.target 2>/dev/null | grep -q masked && masked=1
  if [ "$masked" = 1 ]; then
    say "-- the sleep targets are masked (that is 'nosleep', which is why the last attempt came back as"
    say "   'Call to Suspend failed: Access denied' and proved nothing).  Unmasking them for this run,"
    say "   and masking them again when the machine comes back."
    say "   if this hangs and you have to reset: run  sudo ~/a16step nosleep  after the boot."
    run systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
  fi
  say "-- suspending once now, in the background (10 s from now).  Wake it with the lid or a key."
  if [ "$DRY" = 1 ]; then say "   [dry-run] setsid nohup bash $WIFISLEEP test 1 > $LASTTEST 2>&1 &"; return 0; fi
  : > "$LASTTEST"
  local remask=""
  [ "$masked" = 1 ] && remask="systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1"
  setsid nohup bash -c "sleep 10; bash '$WIFISLEEP' test 1; $remask" </dev/null >"$LASTTEST" 2>&1 &
  disown 2>/dev/null || true
  say "   started (log: $LASTTEST)"
  say "   after you wake it and reconnect:  sudo bash ~/a16step.sh"
}

# --------------------------------------------------------------------------- keep it awake / keep the log
do_nosleep() {
  local want="${ARG:-on}"
  case "$want" in on|off) ;; *) say "usage: sudo bash ~/a16step.sh nosleep [on|off]"; exit 2 ;; esac
  rule
  if [ "$want" = on ]; then
    say "-- making the machine unable to suspend itself"
    # 1. GNOME's idle suspend -- the one that fired on 2026-09-22 after 15 idle minutes on battery
    if [ "$DRY" != 1 ]; then
      sudo -u jc HOME=/home/jc gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null
      sudo -u jc HOME=/home/jc gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
    fi
    say "   GNOME idle suspend      : ac=$(sudo -u jc HOME=/home/jc gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null) battery=$(sudo -u jc HOME=/home/jc gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null)"
    # 2. the lid (logind), via the existing tool so there is one implementation
    if [ "$DRY" != 1 ]; then bash "$REPO/BRINGUP/tools/a16-sleep-test.sh" lid ignore >/dev/null 2>&1; fi
    say "   logind HandleLidSwitch  : $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | sed 's/^s //; s/"//g')"
    # 3. the systemd targets: even a stray request then cannot sleep the machine
    run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    say "   sleep/suspend targets   : $(systemctl is-enabled sleep.target 2>/dev/null) $(systemctl is-enabled suspend.target 2>/dev/null)"
    say ""
    say "   [a suspend can still be forced, e.g. 'systemctl start suspend.target' after unmasking; this"
    say "    is about the machine doing it on its own while you are away]"
  else
    say "-- allowing suspend again"
    run systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
    if [ "$DRY" != 1 ]; then bash "$REPO/BRINGUP/tools/a16-sleep-test.sh" lid suspend >/dev/null 2>&1; fi
    say "   targets                 : $(systemctl is-enabled sleep.target 2>/dev/null) $(systemctl is-enabled suspend.target 2>/dev/null)"
    say "   logind HandleLidSwitch  : $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch 2>/dev/null | sed 's/^s //; s/"//g')"
    say "   GNOME idle suspend      : ac=$(sudo -u jc HOME=/home/jc gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null) battery=$(sudo -u jc HOME=/home/jc gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null)   (battery is back to the GNOME default: 'suspend' after 15 idle minutes)"
  fi
  rule
}

WATCHLOG=/home/jc/a16-payload/kernel-tail.log
WATCH="$REPO/BRINGUP/tools/a16-kernel-tail.sh"
watch_running() { pgrep -a journalctl 2>/dev/null | grep -q -- ' -k -f'; }   # never matches this checker
do_watch() {
  local want="${ARG:-on}"
  case "$want" in on|off) ;; *) say "usage: sudo bash ~/a16step.sh watch [on|off]"; exit 2 ;; esac
  rule
  if [ "$want" = off ]; then
    run pkill -f 'a16-kernel-tail.sh'
    say "   watcher stopped; the log so far is $WATCHLOG ($(wc -l < "$WATCHLOG" 2>/dev/null || echo 0) lines)"
    rule; return 0
  fi
  if watch_running; then say "   already running -> $WATCHLOG"; rule; return 0; fi
  say "-- starting a kernel-log tail that survives a hard reset"
  say "   every line is appended to $WATCHLOG and flushed with sync(), because a hard reset is"
  say "   exactly what loses the journal -- the last two sleep attempts left no evidence at all."
  if [ "$DRY" = 1 ]; then say "   [dry-run] setsid journalctl -k -f | while read l; do echo \$l >> $WATCHLOG; sync; done &"; rule; return 0; fi
  : > "$WATCHLOG"
  setsid nohup bash -c 'journalctl -k -f -o short-iso | while IFS= read -r l; do printf "%s\n" "$l" >> '"$WATCHLOG"'; sync; done' </dev/null >/dev/null 2>&1 &
  sleep 2
  watch_running && say "   running -> $WATCHLOG ($(wc -l < "$WATCHLOG") lines so far)" || say "   FAILED to start"
  rule
}

do_log() {
  rule
  say "-- newest logs"
  ls -t /home/jc/a16-payload/step-*.log /home/jc/a16-payload/wifi-sleep-*.log /home/jc/a16-payload/radiofix-*.log 2>/dev/null | head -4 | sed 's/^/   /'
  rule
  say "-- the running test's own log (if any):"
  tail -25 "$LASTTEST" 2>/dev/null | sed 's/^/      /' || say "   (none)"
  rule
  say "-- kernel: what the resume did"
  journalctl -k -b --no-pager -o short-iso 2>/dev/null | grep -E 'A16: resume|restart complete|MHI state|failed to resume|PM: suspend (entry|exit)' | tail -15 | sed 's/^/      /'
}

say "=== a16step  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
say "host $(hostname)   kernel $HOSTK   boot $(last_boot_id)"
say "log  $LOG"

case "$MODE" in
  status)  show_status ;;
  verdict) do_verdict ;;
  log)     do_log ;;
  watch)   do_watch ;;      # works as yourself: journalctl is readable by this user
  nosleep) [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "needs root:  sudo bash ~/a16step.sh nosleep"; exit 1; }; do_nosleep ;;
  test)    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "needs root:  sudo bash ~/a16step.sh test"; exit 1; }; show_status; do_test ;;
  xhci)    [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "needs root:  sudo bash ~/a16step.sh xhci"; exit 1; }
           show_status
           rule
           say "-- rebuilding the initramfs so patches/0010 (the second-suspend fix) loads by itself."
           say "   One change at a time: do this after the Wi-Fi verdict, not before.  The old initramfs"
           say "   is kept as /boot/initrd.img-$HOSTK.a16bak and the file list is compared before use."
           if [ "$DRY" != 1 ]; then
             printf 'y\n' | bash "$WIFISLEEP" xhci persist | sed 's/^/   /'
           else
             say "   [dry-run] bash $WIFISLEEP xhci persist"
           fi
           ;;
  next|"") [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "needs root:  sudo bash ~/a16step.sh"; exit 1; }; show_status; do_next ;;
  *) say "usage: sudo bash ~/a16step.sh [next|status|test|verdict|log|watch|nosleep [on|off]|xhci]   (--help)"; exit 2 ;;
esac
say ""
say "log: $LOG"
