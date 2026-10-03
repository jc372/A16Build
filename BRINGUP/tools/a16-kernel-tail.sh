#!/usr/bin/env bash
# a16-kernel-tail.sh -- follow the kernel log into a file, flushed, so a hard reset cannot erase it.
#
#   bash a16-kernel-tail.sh [logfile]        (default ~/a16-payload/kernel-tail.log)
#
# Why: the two sleep attempts on 2026-09-22 that ended in a hard reset left NO kernel lines behind at
# all -- journald's writes were still in the page cache when the power went.  This appends every line
# to a plain file and calls sync() as it goes: on a line that mentions suspend/resume/PM/A16/MHI/xhci
# straight away, otherwise every fifth line.  So whatever the machine does before it has to be reset,
# the story is on disk.
#
# Started for you by:  sudo ~/a16step watch        (stop with:  sudo ~/a16step watch off)
set -u
LOG="${1:-/home/jc/a16-payload/kernel-tail.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
printf '=== a16-kernel-tail started %s (kernel %s, boot %s) ===\n' \
       "$(date '+%Y-%m-%d %H:%M:%S')" "$(uname -r)" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" >> "$LOG"
sync
n=0
journalctl -k -f -o short-iso 2>/dev/null | while IFS= read -r l; do
  printf '%s\n' "$l" >> "$LOG"
  n=$((n + 1))
  case "$l" in
    *suspend*|*Suspend*|*resume*|*Resume*|*A16*|*MHI*|*mhi*|*xhci*|*ath12k*|*PM:*) sync ;;
    *) [ $((n % 5)) -eq 0 ] && sync ;;
  esac
done
