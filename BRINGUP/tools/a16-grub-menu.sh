#!/usr/bin/env bash
# a16-grub-menu.sh -- prune the ESP boot menu and add a command-line-only entry.
#
#   sudo bash a16-grub-menu.sh plan       # show exactly what would change (no writes at all)
#   sudo bash a16-grub-menu.sh apply      # back up -> write -> grub-script-check -> auto-restore on failure
#   sudo bash a16-grub-menu.sh list       # the entries as they are now
#   sudo bash a16-grub-menu.sh restore <backup>
#
# Target menu (operator's decision, 2026-10-03):
#   [2] next 7.3 + glymur DTB, panel left to firmware   KEEP  (the failsafe used when [3] fails)
#   [3] next 7.3 + glymur DTB, full display attempt     KEEP  (the entry in daily use)
#   [9] next 7.3 + glymur DTB, command line only        NEW   ([2] + systemd.unit=multi-user.target)
# dropped: [0] installed Ubuntu 7.2, [1] 7.2 + DTB, [4] msm enabled / panel PHY unmanaged,
#          and both [8] Bluetooth-serial entries.
#
# Two things this tool refuses to do, because both already nearly happened:
#   * it will not remove [2] or [3] -- they are the only fallbacks this machine has
#   * it will not write a config that does not parse -- grub-script-check runs first, and the
#     original is only replaced if the check passes (the new file is staged as grub.cfg.new)
# The command-line entry keeps [2]'s blacklist, which is display-only: the internal keyboard,
# touchpad (EC + i2c-hid), the USB stack (xhci/dwc3) and ath12k are untouched, and NetworkManager
# starts in multi-user.target, so Wi-Fi is up.
#
# Log: ~/a16-payload/grub-menu-<timestamp>.log
set -u

CFG=/boot/efi/EFI/ubuntu_snapdragon/grub.cfg
DROPLIST="0 1 4 8"
NEW_LABEL=9
DERIVE_FROM=2                       # the new entry is a copy of [2]
NEW_TITLE='[9] A16: next 7.3 + glymur DTB, command line only (no GUI: systemd.unit=multi-user.target)'
ADD_ARG='systemd.unit=multi-user.target'
MUST_KEEP="2 3"                     # abort if either of these would vanish
DEFAULT_FROM=3                      # `set default` follows [3]'s title, so pruning cannot shift it

LOG_DIR="$HOME/a16-payload"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/grub-menu-$(date +%Y%m%d-%H%M%S).log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { say "FATAL: $*"; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "run as root: sudo bash ~/A16Build/BRINGUP/tools/a16-grub-menu.sh $MODE"; }
[ -f "$CFG" ] || die "no $CFG"

# blocks: label|start|end|title  for every menuentry, braces counted so nested blocks stay intact
blocks() {
  awk '
    /^[[:space:]]*menuentry[[:space:]]/ {
      if (inb) { print label"|"start"|"NR-1"|"title }
      inb=1; start=NR; depth=0; title=""; label=""
      line=$0
      if (match(line, /"[^"]*"/)) { title=substr(line, RSTART+1, RLENGTH-2)
        if (match(title, /^\[[0-9]+\]/)) label=substr(title, RSTART+1, RLENGTH-2) }
    }
    inb { n=gsub(/\{/, "{"); m=gsub(/\}/, "}"); depth += n - m
          if (depth == 0) { print label"|"start"|"NR"|"title; inb=0 } }
  ' "$CFG"
}

show_menu() { while IFS='|' read -r l s e t; do printf '  %-4s %s\n' "[$l]" "$t"; done < <(blocks); }

label_block() { blocks | awk -F'|' -v want="$1" '$1==want{print $2"|"$3; exit}'; }
label_title() { blocks | awk -F'|' -v want="$1" '$1==want{print $4; exit}'; }
label_count() { blocks | awk -F'|' -v want="$1" '$1==want{n++} END{print n+0}'; }

case "${1:-plan}" in
list)
  say "=== $CFG ==="; show_menu
  say ""; say "  set default: $(grep -m1 -E '^[[:space:]]*set[[:space:]]+default=' "$CFG" | sed 's/^[[:space:]]*//')"
  ;;

plan)
  MODE=plan
  say "=== a16-grub-menu: PLAN (no writes) ==="
  say "log: $LOG"; say ""
  say "now:"; show_menu
  n=$(blocks | grep -c .)
  say ""
  say "menuentry blocks found: $n"
  for l in $DROPLIST; do
    c=$(label_count "$l"); [ "$c" = 0 ] && die "label [$l] not found -- refusing to guess"
    say "  would drop [$l] ($c block(s)): $(label_title "$l")"
  done
  for l in $MUST_KEEP; do
    [ "$(label_count "$l")" -ge 1 ] || die "label [$l] missing from the file -- aborting"
  done
  say "  would keep [2] and [3] (verified present) plus the new [$NEW_LABEL]:"
  say "    $NEW_TITLE"
  say "    derived from [$DERIVE_FROM]: $(label_title "$DERIVE_FROM")"
  say "    with one argument added to its linux line: $ADD_ARG"
  say ""
  say "  default follows the [$DEFAULT_FROM] title, so it cannot shift when entries are dropped:"
  say "    set default=\"$(label_title "$DEFAULT_FROM")\""
  say ""
  say "  result: the kept blocks above plus the new [$NEW_LABEL].  NOTE: [5] (stock Ubuntu path), [6]"
  say "    (diagnostics) and [7] (Windows Boot Manager) have no linux line, so this scan never counts"
  say "    them -- they are left in the file exactly as they are.  Expect 6 entries after apply:"
  say "    [2] [3] [5] [6] [7] and the new [$NEW_LABEL].  grub-script-check must pass first."
  ;;

apply)
  MODE=apply; need_root
  say "=== a16-grub-menu: APPLY ==="
  say "log: $LOG"; say ""
  for l in $DROPLIST; do
    [ "$(label_count "$l")" = 0 ] && die "label [$l] not found -- refusing to guess"
  done
  for l in $MUST_KEEP; do
    [ "$(label_count "$l")" -ge 1 ] || die "label [$l] is missing: it is a fallback this machine needs"
  done
  n=$(blocks | grep -c .); [ "$n" -ge 1 ] || die "parsed 0 menuentry blocks -- parser failed, nothing written"

  BAK="$CFG.a16-menu-$(date +%Y%m%d-%H%M%S)"
  cp -a "$CFG" "$BAK" || die "backup failed -- nothing written"
  log "backup: $BAK"

  NEW="$CFG.new"
  # single pass over the file: buffer, find menuentry blocks by brace depth, print the header (with
  # `set default` re-pointed at the kept entry by TITLE, so pruning cannot shift it), then the kept
  # blocks, then the new entry derived from [$DERIVE_FROM].  No asort (gawk-only), no getline.
  awk -v drop="$DROPLIST" -v dfrom="$DERIVE_FROM" -v newlabel="$NEW_LABEL" \
      -v newtitle="$NEW_TITLE" -v addarg="$ADD_ARG" -v def_title="$(label_title "$DEFAULT_FROM")" '
    BEGIN { nd=split(drop, d, " "); for (i=1;i<=nd;i++) dropl[d[i]]=1; nb=0; inb=0 }
    { l[NR]=$0 }
    /^[[:space:]]*menuentry[[:space:]]/ {
      if (inb) end[nb]=NR-1
      nb++; start[nb]=NR; depth=0; ttl=""; lab=""
      line=$0
      if (match(line, /"[^"]*"/)) {
        ttl=substr(line, RSTART+1, RLENGTH-2)
        if (match(ttl, /^\[[0-9]+\]/)) lab=substr(ttl, RSTART+1, RLENGTH-2)
      }
      title[nb]=ttl; label[nb]=lab; inb=1
    }
    inb { o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth += o-c; if (depth==0) { end[nb]=NR; inb=0 } }
    END {
      if (nb < 1) { print "ERROR: no menuentry blocks found" > "/dev/stderr"; exit 1 }
      src=0; for (i=1;i<=nb;i++) if (label[i]==dfrom) src=i
      if (src==0) { print "ERROR: source entry [" dfrom "] not found" > "/dev/stderr"; exit 1 }
      for (i=1;i<start[1];i++) {
        if (l[i] ~ /^[[:space:]]*set[[:space:]]+default=/) printf "  set default=\"%s\"\n", def_title
        else print l[i]
      }
      for (i=1;i<=nb;i++) {
        if (label[i] in dropl) continue
        for (j=start[i];j<=end[i];j++) print l[j]
      }
      for (j=start[src];j<=end[src];j++) {
        line=l[j]
        if (j==start[src]) sub(/"[^"]*"/, "\""newtitle"\"", line)
        if (line ~ /^[[:space:]]*linux[[:space:]]/) line=line" "addarg
        print line
      }
    }' "$CFG" > "$NEW" || die "generation failed -- nothing written"

  [ -s "$NEW" ] || die "generated file is empty -- nothing written"
  if ! grub-script-check "$NEW" 2>>"$LOG"; then
    say "grub-script-check FAILED on the generated file -- original left untouched, $NEW kept for inspection"
    exit 1
  fi
  log "grub-script-check: PASS"
  cp -a "$NEW" "$CFG" || die "install failed"
  rm -f "$NEW"; sync
  log "installed; backup kept at $BAK"
  say ""
  say "new menu:"; show_menu
  say ""; say "  set default: $(grep -m1 -E '^[[:space:]]+set[[:space:]]+default=' "$CFG" | sed 's/^[[:space:]]*//')"
  say ""
  say "WHAT THIS MEANS: reboot and pick [9] to prove the command-line entry (console, keyboard,"
  say "  touchpad, USB, Wi-Fi; no GUI). [2] is still your failsafe and [3] is still the default."
  ;;

restore)
  MODE=restore; B="${2:-}"
  [ -n "$B" ] || die "usage: restore <backup file>"
  need_root; [ -f "$B" ] || die "no such backup: $B"
  cp -a "$CFG" "$CFG.a16-pre-restore-$(date +%Y%m%d-%H%M%S)"; cp -a "$B" "$CFG"; sync
  say "restored from $B"; show_menu
  ;;

*) say "usage: sudo bash a16-grub-menu.sh {plan|apply|list|restore <backup>}" ;;
esac
say ""; say "log: $LOG"
