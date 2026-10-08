#!/usr/bin/env bash
# a16-efi-order.sh -- which firmware boot option wins: Windows Boot Manager or Ubuntu (GRUB).
#
#   sudo bash ~/a16.sh efi status      # read-only: the entries and the current order
#   sudo bash ~/a16.sh efi windows     # make Windows Boot Manager the default
#   sudo bash ~/a16.sh efi ubuntu      # make the Ubuntu/GRUB entry the default again
#   sudo bash ~/a16.sh efi restore     # put back the order saved by the last change
#   bash a16-efi-order.sh selftest     # no root: check the parsing against a sample dump
#
# What it does and does not do: it reorders BootOrder and nothing else.  It never creates,
# deletes or rewrites a boot entry, so no loader path can be lost whatever happens.
# Before any change, the current order and the full `efibootmgr -v` listing are saved to
# ~/a16-payload/efi-bootorder-<timestamp>.txt -- that file is what `restore` reads.
#
# Why it exists: the A16's UEFI boots whichever entry BootOrder lists first, and the Ubuntu
# installer puts its own first.  So the firmware default is Ubuntu no matter what Windows
# wants.  This flips it deliberately -- and `ubuntu` (or `restore`) flips it back.
#
# Env for testing: A16_LOG_DIR, A16_EFIBOOTMGR, A16_DUMP (use a file instead of the firmware).
set -u

LOG_DIR=${A16_LOG_DIR:-/home/jc/a16-payload}
EFIBOOTMGR=${A16_EFIBOOTMGR:-efibootmgr}
MODE=${1:-status}

say() { printf '%s\n' "$*"; }

dump() {
  if [ -n "${A16_DUMP:-}" ]; then cat "$A16_DUMP"; else "$EFIBOOTMGR" -v 2>/dev/null; fi
}

# identify: takes an efibootmgr dump as its argument, prints "windows <num>", "ubuntu <num>", "bootorder <csv>"
identify() {
  python3 - "$1" <<'PY'
import sys, re
text = sys.argv[1]
win = ubu = None
order = "-"
for line in text.splitlines():
    m = re.match(r'Boot([0-9A-Fa-f]{4})(\*?)\s+(.*)$', line)
    if m:
        num, active, rest = m.group(1).upper(), m.group(2), m.group(3)
        low = rest.lower()
        if win is None and ('\\efi\\microsoft\\boot\\bootmgfw.efi' in low or 'windows boot manager' in low):
            win = num + ('' if active else '!')
        if ubu is None and (re.search(r'\\efi\\ubuntu[a-z_]*\\', low) or 'ubuntu' in low):
            ubu = num + ('' if active else '!')
        continue
    m2 = re.match(r'BootOrder:\s*(.*)$', line)
    if m2 and m2.group(1).strip():
        order = m2.group(1).strip()
print("windows %s" % (win or "-"))
print("ubuntu %s" % (ubu or "-"))
print("bootorder %s" % order)
PY
}

# reorder: $1 = target number, $2 = current order csv -> prints the new order with target first
reorder() {
  python3 - "$1" "$2" <<'PY'
import sys
target, order = sys.argv[1], sys.argv[2]
items = [x.strip() for x in order.split(',') if x.strip()]
items = [x for x in items if x.upper() != target.upper()]
print(target + (',' + ','.join(items) if items else ''))
PY
}

# save: write the pre-change state where the operator can read it
save() {
  local f="$LOG_DIR/efi-bootorder-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$LOG_DIR"
  { say "# a16-efi-order.sh $* -- saved $(date -Is)"; say "# before:"; dump; } > "$f" 2>&1
  chmod 644 "$f" 2>/dev/null || true
  say "$f"
}

selftest() {
  local sample
  sample=$(cat <<'EOF'
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0000,0002,0004
Boot0000* Windows Boot Manager	HD(1,GPT,abcd,0x800,0x100000)/\EFI\Microsoft\Boot\bootmgfw.efi
Boot0001* ubuntu	HD(1,GPT,abcd,0x800,0x100000)/\EFI\ubuntu\shimaa64.efi
Boot0002* ubuntu_snapdragon	HD(1,GPT,abcd,0x800,0x100000)/\EFI\ubuntu_snapdragon\shimaa64.efi
Boot0004* UEFI PXEv4	BBS(Network,0x0)
EOF
)
  local w u o
  w=$(identify "$sample" | awk '$1=="windows"{print $2}')
  u=$(identify "$sample" | awk '$1=="ubuntu"{print $2}')
  o=$(identify "$sample" | awk '$1=="bootorder"{print $2}')
  say "selftest: windows=$w ubuntu=$u order=$o"
  say "selftest: windows-first  -> $(reorder "$w" "$o")"
  say "selftest: ubuntu-first   -> $(reorder "$u" "$o")"
  [ "$w" = "0000" ] && [ "$u" = "0001" ] && [ "$o" = "0001,0000,0002,0004" ] \
    && say "selftest: PASS" || { say "selftest: FAIL"; return 1; }
}

case "$MODE" in
  -h|--help|help)
    sed -n '2,17p' "$0"; exit 0 ;;
  selftest) selftest; exit $? ;;
esac

if [ "$MODE" != "status" ] && [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-${SKIP_ROOT:-0}}" != 1 ]; then
  say "This needs root.  Type exactly:"
  say ""
  say "    sudo bash ~/a16.sh efi $MODE"
  say ""
  exit 1
fi

[ -d /sys/firmware/efi/efivars ] || { say "No efivars: this is not an EFI boot."; exit 1; }

BEFORE=$(dump)
WIN=$(identify "$BEFORE" | awk '$1=="windows"{print $2}')
UBU=$(identify "$BEFORE" | awk '$1=="ubuntu"{print $2}')
ORDER=$(identify "$BEFORE" | awk '$1=="bootorder"{print $2}')

say "-- now"
printf '%s\n' "$BEFORE" | sed 's/^/   /'
say ""
say "-- identified:  windows=${WIN:-?}  ubuntu=${UBU:-?}  BootOrder=$ORDER"
say ""

case "$MODE" in
  status)
    say "Use: efi windows | efi ubuntu | efi restore"
    exit 0 ;;
  windows|ubuntu)
    if [ "$MODE" = windows ]; then TARGET=${WIN%!}; LABEL="Windows Boot Manager"; else TARGET=${UBU%!}; LABEL="Ubuntu (GRUB)"; fi
    [ -n "${TARGET:-}" ] && [ "$TARGET" != "?" ] && [ "$TARGET" != "-" ] \
      || { say "Could not identify the $LABEL entry in the list above -- nothing changed."; exit 2; }
    case "${TARGET}" in *'!') say "The $LABEL entry exists but is NOT active; activate it first with:"; say "    efibootmgr -b $TARGET -a"; exit 2 ;; esac
    case "$MODE" in windows) case "${WIN:-}" in *'!') say "The Windows entry is not active; activate it first:  efibootmgr -b ${WIN%!} -a"; exit 2 ;; esac ;; esac
    case "$MODE" in ubuntu) case "${UBU:-}" in *'!') say "The Ubuntu entry is not active; activate it first:  efibootmgr -b ${UBU%!} -a"; exit 2 ;; esac ;; esac
    SAVED=$(save "$MODE")
    NEW=$(reorder "$TARGET" "$ORDER")
    say "-- setting BootOrder: $ORDER  ->  $NEW"
    "$EFIBOOTMGR" -o "$NEW" || { say "efibootmgr -o failed; nothing changed.  Saved state: $SAVED"; exit 3; }
    say ""
    say "-- after"
    dump | sed 's/^/   /'
    say ""
    say "-- done: $LABEL boots next time."
    say "   back to Ubuntu:  sudo bash ~/a16.sh efi ubuntu"
    say "   exact undo:      sudo bash ~/a16.sh efi restore      (state saved in $SAVED)" ;;
  restore)
    LAST=$(ls -t "$LOG_DIR"/efi-bootorder-*.txt 2>/dev/null | head -1)
    [ -n "${LAST:-}" ] || { say "No saved state in $LOG_DIR -- nothing to restore."; exit 2; }
    OLD=$(awk -F': *' '$1=="BootOrder"{print $2}' "$LAST" | tail -1)
    [ -n "${OLD:-}" ] || { say "Could not read a BootOrder out of $LAST."; exit 2; }
    say "-- restoring BootOrder from $LAST"
    say "   $ORDER  ->  $OLD"
    "$EFIBOOTMGR" -o "$OLD" || { say "efibootmgr -o failed; nothing changed."; exit 3; }
    say ""
    dump | sed 's/^/   /' ;;
  *)
    say "usage: bash $0 [status|windows|ubuntu|restore|selftest]"; exit 2 ;;
esac
