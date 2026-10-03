#!/usr/bin/env bash
# a16-grub-dedupe.sh -- drop duplicate copies of the Bluetooth test menu entry.
#
#   sudo bash a16-grub-dedupe.sh            # report + fix every config, backups kept
#   bash a16-grub-dedupe.sh --dry-run       # report only
#
# Why this exists: a16-bt-dtb.sh decided whether the menu entry was already present with
#
#     if grep -q "$ENTRY_TITLE" "$cfg"
#
# and $ENTRY_TITLE starts with "[8]" -- in a basic regex that is a *character class*, so the
# pattern is `8] A16: ...` and it never matches the literal `[8] A16: ...` in the file.  Every
# install run therefore appended another copy of the entry: this machine's four configs each
# carry it twice (a menu with two identical rows, both loading the same DTB).  The check is
# fixed to grep -F for the DTB filename; this script cleans up what the old one wrote.
#
# What it does per config: keeps the FIRST menuentry block whose body references
# glymur-a16-bt-test.dtb and deletes the later ones.  A backup is written next to it
# (grub.cfg.a16dedupe-<timestamp>) and grub-script-check re-checks the result.
set -u

ESP="${A16_ESP:-/boot/efi}"
MARKER="${A16_BT_DTB_NAME:-glymur-a16-bt-test.dtb}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

CONFIGS="$ESP/a16boot/grub.cfg $ESP/EFI/Boot/grub.cfg $ESP/EFI/ubuntu/grub.cfg $ESP/EFI/ubuntu_snapdragon/grub.cfg"
TESTMODE=0
[ -n "${A16_ESP:-}" ] && TESTMODE=1     # an overridden ESP is a test hook: no root needed
# resolve the log AFTER the sudo HOME redirect, or a sudo run logs where nobody can read it
[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
LOG="${A16_LOG:-$HOME/a16-payload/A16GRUBDEDUPE-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || LOG="/var/tmp/a16-grub-dedupe-$(date +%Y%m%d-%H%M%S).log"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
say "[a16-grub-dedupe] === $(date +%Y%m%d-%H%M%S) ===  marker: $MARKER  dry-run=$DRY"
if [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ] && [ "$TESTMODE" = 0 ]; then
  say "[a16-grub-dedupe] needs root:  sudo bash $0"; exit 1
fi

for cfg in $CONFIGS; do
  [ -f "$cfg" ] || { say "   (absent) $cfg"; continue; }
  before="$(grep -c "$MARKER" "$cfg" 2>/dev/null || echo 0)"
  if [ "$before" -le 1 ]; then say "   ok       $cfg  ($before block(s) referencing $MARKER)"; continue; fi
  if [ "$DRY" = 1 ]; then say "   WOULD FIX $cfg  ($before blocks)"; continue; fi
  bak="$cfg.a16dedupe-$(date +%Y%m%d-%H%M%S)"
  cp -a "$cfg" "$bak" || { say "   BACKUP FAILED $cfg"; continue; }
  python3 - "$cfg" "$MARKER" <<'PY' || { say "   FAILED  $cfg (backup kept at $bak)"; continue; }
import sys
path, marker = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
out, block, seen = [], [], 0
def flush():
    global block, seen
    if not block:
        return
    if any(marker in l for l in block):
        seen += 1
        if seen == 1:
            out.extend(block)
    else:
        out.extend(block)
    block = []
for l in lines:
    if l.startswith("menuentry "):
        flush()
    block.append(l)
flush()
open(path, "w").writelines(out)
print("   kept 1 of %d block(s) referencing %s" % (seen, marker))
PY
  after="$(grep -c "$MARKER" "$cfg" 2>/dev/null || echo 0)"
  say "   FIXED    $cfg  $before -> $after block(s)   backup: $bak"
  grub-script-check "$cfg" >/dev/null 2>&1 && say "            grub-script-check: clean" || say "            grub-script-check: WARNING (check $cfg by hand)"
done

say "[a16-grub-dedupe] the menu should now show one Bluetooth row per config."
say "[a16-grub-dedupe] log: $LOG"
