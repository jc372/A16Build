#!/usr/bin/env bash
# a16-resume-log.sh -- the suspend/resume lines of the journal, as one short command.
#
#   resume_log            this boot: suspend attempts, what the resume did, what killed the radio
#   resume_log 1          the boot before this one (2, 3 … work the same way)
#   resume_log all        the previous boot and this one
#
# No root needed (this user is in adm).  Written 2026-09-22 because the console may be a black screen
# and the line that matters --
#   sudo journalctl -k -b | grep -E 'A16: resume|restart complete|MHI state|failed to resume'
# -- is far too long to type from an ssh session.  Output is also saved to
# ~/a16-payload/LAST-RESUME.txt so it can be read again (or copied) with one short path.
#
# How to read it:
#   PM: suspend entry (deep|s2idle) … PM: suspend exit        a suspend that happened
#   PM: Some devices failed to suspend / failed to suspend async
#                                                            a suspend that ABORTED; the device is named
#                                                            just above, and -22 at xhci-hcd.*.auto means
#                                                            patches/0010 is not the loaded module
#   A16 suspend: / A16 resume:                                the patched xhci-plat-hcd.ko talking
#                                                            (absent = the stock module is loaded)
#   A16: resume -- … MHI state 0x{?}                          patches/0014 talking (ath12k)
#   mhi mhi0: Wait for device to enter SBL or Mission mode    the device came out of the suspend with
#                                                            no firmware running
#   timeout while waiting for restart complete / failed to resume core: -110
#                                                            the resume gave up; the radio is dead until
#                                                            a restart
#   wmi command 16387 timeout / fail to start mac operations  the wedge, after the fact
set -u

WHICH="${1:-}"
OUTDIR=/home/jc/a16-payload
OUT="$OUTDIR/LAST-RESUME.txt"
PATTERN='PM: suspend (entry|exit)|Some devices failed|failed to suspend async|failed to resume|dpm_run_callback|timeout while waiting for restart|restart complete|Wait for device to enter SBL|MHI state|A16: |A16 suspend|A16 resume|wmi command|fail to start mac operations'
mkdir -p "$OUTDIR" 2>/dev/null

say() { printf '%s\n' "$*"; }
print_boot() {   # args: journalctl boot selector
  journalctl -k "$@" --no-pager -o short-iso 2>/dev/null | grep -E "$PATTERN" | tail -45
}

case "$WHICH" in
  ''|save|all|1|2|3|4) ;;
  *) say "usage: resume_log [1|2|3|all]     (no argument = this boot)"; exit 2 ;;
esac

{
  say "=== the suspend/resume lines  $(date '+%Y-%m-%d %H:%M:%S') ==="
  say "kernel $(uname -r)   this boot $(cat /proc/sys/kernel/random/boot_id)"
  say "suspends recorded this boot : $(journalctl -k -b --no-pager -o cat 2>/dev/null | grep -c 'PM: suspend entry')"
  say "loaded ath12k               : $(cat /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume 2>/dev/null && echo '-- patches/0014' || echo 'stock build')"
  say "loaded xhci-plat-hcd        : $(cat /sys/module/xhci_plat_hcd/parameters/a16_state_log 2>/dev/null && echo '-- patches/0010' || echo 'stock build')"
  say "radio now                   : $(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: '$1 ~ /^wl/{printf "%s %s", $1, $2}' | head -1)"
  say ""

  case "$WHICH" in
    ''|save) print_boot -b ;;
    1|2|3|4) say "---------------- boot -$WHICH ----------------"; print_boot -b "-$WHICH" ;;
    all) say "---------------- previous boot ----------------"; print_boot -b -1
         say ""; say "---------------- this boot ----------------"; print_boot -b ;;
  esac

  say ""
  say "--- how to read it ---"
  say "  'A16: resume' present          patches/0014 is loaded and its resume path ran"
  say "  'Wait for device to enter SBL'   a device restarted with no firmware to run.  Normal ONCE at"
  say "                                   boot (the cold boot is given one); fatal after a resume"
  say "  'failed to resume core: -110'     the resume gave up: the radio needs a restart"
  say "  no 'PM: suspend entry'         nothing has suspended on this boot"
  say "  nothing at all, and the box looks hung   the journal did not flush (a hard reset);"
  say "                                           the tool logs under ~/a16-payload/ are the record"
} 2>&1 | tee "$OUT"

say ""
say "saved to $OUT"
