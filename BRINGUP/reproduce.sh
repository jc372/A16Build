#!/usr/bin/env bash
# reproduce.sh -- run the A16 bring-up steps in order, or check the current state.
#
#   bash reproduce.sh --list              # what the steps are and what each one needs
#   bash reproduce.sh --check             # read-only: preflight + the acceptance checks
#   sudo bash reproduce.sh                # run every step in order
#   sudo bash reproduce.sh --from 40      # resume at a step (use after the reboots)
#   sudo bash reproduce.sh --only 50      # one step
#
# The steps, and where a reboot is expected:
#
#   00-preflight   read-only    machine identity, tools, payload, current state
#   10-kernel      root         installs the kernel + modules + machine DTB + the boot menu
#                 >>> REBOOT and choose a device-tree entry (on this machine: [1]) <<<
#   20-dt-boot     read-only    proves the DT boot (internal input, panel) or tells you to re-stage
#   30-firmware    root         DSP blobs + Bluetooth blobs into /lib/firmware
#   40-wifi        root         serve this machine's own board data to ath12k, then verify
#   50-bluetooth   root         build + install + arm the patched DTB (uart14 serdev client + the
#                               Bluetooth kill-line flip)
#                 >>> REBOOT -- no menu interaction needed, the armed paths carry it <<<
#   60-verify      read-only    the acceptance checks
#
# Nothing here is destructive: every step that writes takes a backup, prints the log path, and
# can be undone (see a16-bt-arm.sh revert, a16-bt-dtb.sh, a16-grub-dedupe.sh).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STEPS_DIR="$HERE/steps"
LOG="${A16_LOG:-$HOME/a16-payload/A16REPRODUCE-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

STEP_LIST="00-preflight 10-kernel 20-dt-boot 30-firmware 40-wifi 50-bluetooth 60-verify"
step_desc() {
  case "$1" in
    00-preflight) echo "read-only    machine identity, tools, payload bundle, current state";;
    10-kernel)    echo "root         kernel + modules + machine DTB + the 9-entry boot menu   [REBOOT after]";;
    20-dt-boot)   echo "read-only    prove the DT boot (internal input, panel, backlight state)";;
    30-firmware)  echo "root         DSP firmware + Bluetooth blobs into /lib/firmware";;
    40-wifi)      echo "root         this machine's QCC2072 board data for ath12k, then verify";;
    50-bluetooth) echo "root         patched DTB (serdev client + kill-line flip), install + arm [REBOOT after]";;
    60-verify)    echo "read-only    acceptance checks (required + known-open info)";;
  esac
}
run_step() {
  local s="$1" f
  f="$(ls "$STEPS_DIR/$s"*.sh 2>/dev/null | head -1)"
  [ -n "$f" ] || { say "no such step: $s"; return 2; }
  say ""
  say "────────────────────────────────────────────────────────────────────────"
  say "step $s -- $(step_desc "$s")"
  say "────────────────────────────────────────────────────────────────────────"
  bash "$f" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

MODE="${1:-run}"; ARG="${2:-}"
case "$MODE" in
  --list)
    say "A16 bring-up steps ($(date +%Y%m%d-%H%M%S))"
    for s in $STEP_LIST; do say "  $s  $(step_desc "$s")"; done
    say ""
    say "reboots: after 10-kernel (pick a DT entry) and after 50-bluetooth (nothing to pick)."
    exit 0;;
  --check)
    run_step 00-preflight; rc=$?
    say ""
    run_step 60-verify
    [ "$rc" = 0 ] || { say "preflight failed -- fix that first"; exit "$rc"; }
    exit $?;;
  --only)
    [ -n "$ARG" ] || { say "--only needs a step (e.g. --only 50)"; exit 2; }
    run_step "$ARG"; exit $?;;
  --from)
    [ -n "$ARG" ] || { say "--from needs a step (e.g. --from 40)"; exit 2; }
    started=0
    for s in $STEP_LIST; do
      [ "$s" = "$ARG" ] && started=1
      [ "$started" = 1 ] || continue
      run_step "$s" || { say ""; say "step $s failed -- stopping (re-run with --from $s after fixing)"; exit 1; }
    done
    say ""; say "all steps from $ARG ran.  log: $LOG"; exit 0;;
  run|"")
    [ "$(id -u)" = 0 ] || { say "running the full pipeline needs root for steps 10/30/40/50: sudo bash $0"; exit 1; }
    for s in $STEP_LIST; do
      run_step "$s" || { say ""; say "step $s failed -- stopping (re-run with --from $s after fixing)"; exit 1; }
      case "$s" in
        10-kernel)    say ""; say ">>> REBOOT now and choose a device-tree entry ([1] on this machine), then: sudo bash $0 --from 20"; exit 0;;
        50-bluetooth) say ""; say ">>> REBOOT now (no menu interaction needed), then: sudo bash $0 --from 60"; exit 0;;
      esac
    done
    say ""; say "done.  log: $LOG";;
  *) say "usage: $0 [--list|--check|--from STEP|--only STEP]"; exit 2;;
esac
