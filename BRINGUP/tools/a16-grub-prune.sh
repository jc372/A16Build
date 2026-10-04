#!/usr/bin/env bash
# a16-grub-prune.sh -- remove boot menu entries whose kernel is no longer on the disk.
#
#   bash a16-grub-prune.sh                 # dry run: what would be removed (default)
#   bash a16-grub-prune.sh --list          # every entry, and whether its files exist
#   sudo bash a16-grub-prune.sh --apply    # remove them: backup, rewrite, syntax-check
#
# The rule is the only one that is safe to automate: an entry that names a vmlinuz which is not on
# the disk cannot boot, so it is dead weight. Entries with no kernel line at all -- Windows, the
# diagnostics screen, Ubuntu's own generated menu -- are never touched, and at least one working
# A16 entry is always kept even if the tool thinks otherwise.
#
# Nothing is written without --apply, and --apply always leaves a timestamped backup of the menu
# beside it plus a grub-script-check pass. Dry run is the default so a careless run is harmless.
#
# Sandbox (test against a copy of the menu, nothing real is touched):
#   A16_ROOT=/tmp/a16sb A16_ALLOW_NONROOT=1 bash a16-grub-prune.sh --apply
set -u

R="${A16_ROOT:-}"; [ -n "$R" ] && SANDBOX=1 || SANDBOX=0
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
MODE="${1:---dry-run}"

case "$MODE" in
	--dry-run|--apply|--list) : ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "usage: $0 [--dry-run|--list|--apply]"; exit 2 ;;
esac
if [ "$MODE" = "--apply" ] && [ "${A16_ALLOW_NONROOT:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "FATAL: --apply needs root: sudo bash $0 --apply"; exit 1; }
fi

MENU=""
for c in "$R"/boot/efi/EFI/*/grub.cfg "$R"/boot/EFI/EFI/*/grub.cfg "$R"/boot/efi/EFI/*/*/grub.cfg; do
	[ -f "$c" ] && MENU="$c" && break
done
[ -n "$MENU" ] || { echo "FATAL: no GRUB menu found under ${R}/boot/efi or ${R}/boot/EFI"; exit 1; }

BEFORE="$(grep -cE '^[[:space:]]*menuentry' "$MENU")"
printf '\nmenu: %s   (%s entries)\n' "${MENU##"$R"}" "$BEFORE"
[ "$SANDBOX" = 1 ] && printf 'sandbox: %s (nothing outside it is touched)\n' "$R"

python3 - "$MENU" "$MODE" "$R" <<'PY'
import os, re, sys
menu, mode, R = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(menu).read()

# every menuentry block, with its brace extent, so removal cannot cut into a neighbour
blocks = []
for m in re.finditer(r'(?m)^([ \t]*)menuentry\s+"([^"]+)"\s*\{', text):
    j = m.end() - 1; depth = 0
    while j < len(text):
        if text[j] == '{': depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    blocks.append({'start': m.start(), 'end': j + 1, 'title': m.group(2),
                   'body': text[m.start():j + 1]})

def paths(body):
    k = re.search(r'^\s*linux\s+(\S+)', body, re.M)
    i = re.search(r'^\s*initrd\s+(\S+)', body, re.M)
    d = re.search(r'^\s*devicetree\s+(\S+)', body, re.M)
    return (k.group(1) if k else None,
            i.group(1) if i else None,
            d.group(1) if d else None)

def exists(p):
    return True if p is None else os.path.exists(R + p)

dead, keep, nokernel = [], [], []
for b in blocks:
    k, i, d = paths(b['body'])
    if k is None:
        nokernel.append(b)          # Windows, diagnostics, Ubuntu's own entry: never touched
    elif not exists(k):
        dead.append(b)
    else:
        keep.append(b)

print(f"  {len(blocks)} entries: {len(keep)} bootable, {len(dead)} naming a missing kernel, "
      f"{len(nokernel)} without a kernel line")

if mode == '--list' or mode == '--dry-run':
    for b in blocks:
        k, i, d = paths(b['body'])
        if k is None:      state = 'no kernel line   (kept)'
        elif not exists(k): state = 'KERNEL MISSING   (would go)'
        else:              state = 'ok'
        print(f"    [{state}] {b['title'][:66]}")
        if k: print(f"          {k}")

# a menu with no bootable A16 entry left is worse than a cluttered one
if dead and not keep:
    print("  refusing: every entry with a kernel points at a missing file; that cannot be right")
    sys.exit(1)

if mode == '--list':
    sys.exit(0)
if not dead:
    print("  nothing to remove -- every entry naming a kernel has one on the disk")
    sys.exit(0)
if mode == '--dry-run':
    print(f"\n  would remove {len(dead)} entr{'y' if len(dead)==1 else 'ies'}:")
    for b in dead: print(f"    - {b['title'][:70]}")
    print("  run with --apply to do it (backup taken first)")
    sys.exit(0)

# ---- apply
out, prev = [], 0
for b in dead:
    out.append(text[prev:b['start']]); prev = b['end']
out.append(text[prev:])
new = ''.join(out)
new = re.sub(r'\n{3,}', '\n\n', new)
open(menu, 'w').write(new)
print(f"  removed {len(dead)} entr{'y' if len(dead)==1 else 'ies'}; {len(keep) + len(nokernel)} remain")
PY
rc=$?
[ "$MODE" = "--apply" ] && [ "$rc" = 0 ] || exit $rc

# only rewrite if something actually changed; keep a backup in every case
BAK="$MENU.a16prune-$STAMP"
NOW="$(grep -cE '^[[:space:]]*menuentry' "$MENU")"
if [ "$NOW" -lt "$BEFORE" ]; then
	cp -f "$MENU" "$BAK" && printf '  backup: %s\n' "${BAK##"$R"}"
	if command -v grub-script-check >/dev/null 2>&1; then
		if grub-script-check "$MENU" 2>/dev/null; then printf '  grub-script-check: ok\n'
		else printf '  grub-script-check complained -- restore %s if in doubt\n' "${BAK##"$R"}"; fi
	fi
	printf '  entries now: %s (was %s)\n' "$(grep -cE '^[[:space:]]*menuentry' "$MENU")" "$BEFORE"
fi
