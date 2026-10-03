#!/usr/bin/env bash
# a16-arm-kdump.sh -- arm kdump so the next kernel panic leaves a backtrace we can read.
#
# Why: this machine panics on some resume attempts (the EC indicator LEDs flash, the panel goes
# dark, and with panic=0 it just sits there until the power button is held).  A panic during
# suspend/resume leaves NOTHING behind: the journal's tail is lost with the hard reset, and
# efi_pstore cannot write its EFI variable while the runtime services are down mid-suspend, so
# /sys/fs/pstore stays empty.  But the cmdline already reserves a crash kernel:
#
#     crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M
#
# and kexec + makedumpfile are installed.  With the crash kernel loaded, a panic boots into it and
# writes a dump; /var/crash/<stamp>/vmcore-dmesg.txt is plain text -- the last words of the failed
# resume, readable after a reboot.
#
# Phases (idempotent, safe to re-run):
#   status   show whether the crash kernel is loaded and what would be captured (no root needed)
#   arm      enable USE_KDUMP, load the crash kernel, verify (root)
#   disarm   stop capturing (root)
#   test     status + the exact commands to read a dump after a failure
#
# Usage:  sudo bash ~/a16.sh kdump          (arm; the operator-facing line)
#         sudo bash ~/a16.sh kdump status   (read-only)
set -u
A16_LOG_DIR="${A16_LOG_DIR:-$HOME/a16-payload}"
mkdir -p "$A16_LOG_DIR" 2>/dev/null || true
LOG="$A16_LOG_DIR/kdump-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG" 2>/dev/null || true
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sayk() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf '(unreadable)'; }

MODE="${1:-arm}"
DEF=/etc/default/kdump-tools
COREDIR=/var/crash
[ "$(id -u)" = 0 ] || { echo "run with sudo:  sudo bash ~/a16.sh kdump [status|arm|disarm]"; exit 1; }

status() {
  say "-- status"
  say "   crash kernel loaded : $(sayk /sys/kernel/kexec_crash_loaded)   (1 = armed)"
  say "   crashkernel reserve : $(grep -i 'Crash kernel' /proc/iomem | head -1 | sed 's/^ *//')"
  say "   kexec_load_disabled : $(sayk /proc/sys/kernel/kexec_load_disabled)"
  say "   panic / panic_on_oops: $(sayk /proc/sys/kernel/panic) / $(sayk /proc/sys/kernel/panic_on_oops)"
  say "   tools               : kexec=$(command -v kexec || echo missing) makedumpfile=$(command -v makedumpfile || echo missing)"
  for u in kdump-tools kdump; do
    say "   unit $u: $(systemctl is-enabled $u 2>/dev/null || echo not-found) / $(systemctl is-active $u 2>/dev/null || echo inactive)"
  done
  say "   $DEF: $(grep -c . $DEF 2>/dev/null || echo 0) lines; USE_KDUMP=$(grep -E '^USE_KDUMP' $DEF 2>/dev/null | tail -1 | cut -d= -f2)"
  say "   dumps in $COREDIR:"
  ls -1 "$COREDIR" 2>/dev/null | sed 's/^/      /' | head -8
  say "   kernel cmdline crashkernel: $(tr ' ' '\n' < /proc/cmdline | grep '^crashkernel=' | head -1)"
  say "   read-only status finished; log: $LOG"
}

arm() {
  status
  say ""
  say "-- arming"
  command -v kexec >/dev/null || { say "   kexec is missing -- install kexec-tools first"; exit 1; }
  command -v makedumpfile >/dev/null || { say "   makedumpfile is missing"; exit 1; }

  if [ ! -f "$DEF" ]; then say "   $DEF is missing (kdump-tools not installed)"; exit 1; fi
  cp -a "$DEF" "$DEF.a16-backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  sed -i -e 's/^#\?USE_KDUMP=.*/USE_KDUMP=1/' \
         -e 's|^#\?KDUMP_COREDIR=.*|KDUMP_COREDIR="'"$COREDIR"'"|' "$DEF"
  grep -qE '^USE_KDUMP=' "$DEF" || echo 'USE_KDUMP=1' >> "$DEF"
  grep -qE '^KDUMP_COREDIR=' "$DEF" || echo "KDUMP_COREDIR=\"$COREDIR\"" >> "$DEF"
  say "   $DEF now:"; grep -vE '^#|^$' "$DEF" | sed 's/^/      /' | tee -a "$LOG"

  if systemctl list-unit-files 2>/dev/null | grep -q '^kdump-tools'; then
    say "   restarting kdump-tools.service"
    systemctl restart kdump-tools 2>&1 | sed 's/^/      /' | tee -a "$LOG"
  else
    say "   no kdump-tools.service; trying kdump-config"
    if command -v kdump-config >/dev/null; then
      kdump-config load 2>&1 | sed 's/^/      /' | tee -a "$LOG"
    else
      say "   kdump-config is missing too -- install kdump-tools (apt install kdump-tools)"
    fi
  fi

  sleep 1
  loaded=$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || echo 0)
  say ""
  say "-- verify: crash kernel loaded = $loaded  (1 = armed)"
  if [ "$loaded" != 1 ]; then
    say "   NOT armed.  Usual causes on arm64:"
    say "     * the crashkernel reservation is smaller than this kernel needs"
    say "     * kdump needs the device tree: /sys/firmware/fdt must be passed as --dtb="
    say "     * kdump-tools could not find the initrd for the crash kernel"
    say "   dmesg from the load attempt:"; dmesg 2>/dev/null | tail -5 | sed 's/^/      /'
    say "   Send me this log: $LOG"
  else
    say "   ARMED.  After the next panic:"
    say "     ls -lt $COREDIR | head           # newest dump directory"
    say "     cat $COREDIR/<stamp>/vmcore-dmesg.txt   # plain text: the backtrace"
  fi
  say "   disarm with:  sudo bash ~/a16.sh kdump disarm"
  say "   log: $LOG"
}

disarm() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^kdump-tools'; then
    systemctl stop kdump-tools 2>&1 | sed 's/^/   /' | tee -a "$LOG"
  fi
  say "-- disarmed: crash kernel loaded = $(sayk /sys/kernel/kexec_crash_loaded)"
}

case "$MODE" in
  status) status ;;
  arm)    arm ;;
  disarm) disarm ;;
  *) echo "usage: sudo bash ~/a16.sh kdump [status|arm|disarm]"; exit 2 ;;
esac
