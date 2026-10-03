#!/usr/bin/env bash
# a16-grub-prune.sh -- remove stale [10] kernel entries, keep the current one.
#
#   bash a16-grub-prune.sh --dry-run     # show what would go (default)
#   sudo bash a16-grub-prune.sh --apply  # do it: backup, rewrite, grub-script-check
#
# Why: every install-beside run appended a menu entry titled "[10] A16: ...". Six piled up,
# and most now point at kernels that have been deleted. This keeps the one whose kernel
# still exists and is newest, and removes the rest.
#
# Every other entry is left exactly as it is: [2] failsafe, [3] known-good, [5] Ubuntu,
# [6] diagnostics, [7] Windows Boot Manager, [9] no-GUI command line.
set -u
ESP="${A16_ESP:-/boot/efi}"
CFG="${A16_GRUB_CFG:-$ESP/EFI/ubuntu_snapdragon/grub.cfg}"
KEEP="${A16_GRUB_KEEP:-mon1}"        # substring identifying the entry to keep
MODE="${1:---dry-run}"

[ -f "$CFG" ] || { echo "FATAL: no $CFG"; exit 1; }
if [ "$MODE" = "--apply" ] && [ "$(id -u)" != 0 ]; then
  echo "FATAL: --apply needs root:  sudo bash $0 --apply"; exit 1
fi

python3 - "$CFG" "$KEEP" "$MODE" <<'PY'
import sys, os, re, glob, shutil, subprocess
cfg, keep, mode = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(cfg).read().split('\n')

starts = [i for i, l in enumerate(lines) if l.startswith('menuentry')]
blocks = []
for n, s in enumerate(starts):
    e = starts[n + 1] if n + 1 < len(starts) else len(lines)
    while e > s and lines[e - 1].strip() == '':
        e -= 1
    blocks.append([s, e])

print(f"  {len(blocks)} menuentry blocks in {cfg}")

def kernel_of(block):
    for l in lines[block[0]:block[1]]:
        m = re.search(r'/boot/vmlinuz-(\S+)', l)
        if m:
            return m.group(1)
    return None

keep_block, remove = None, []
for b in blocks:
    title = lines[b[0]]
    if '"[10]' not in title:
        continue
    k = kernel_of(b)
    exists = bool(k) and os.path.exists('/boot/vmlinuz-' + k)
    if keep in title and exists:
        keep_block = b
    else:
        why = 'kernel deleted' if not exists else 'superseded'
        remove.append((b, title.strip(), why))

if keep_block:
    print(f"  keeping : {lines[keep_block[0]].strip()[:100]}")
else:
    print(f"  WARNING: no [10] entry matching {keep!r} with an existing kernel")
    print("           nothing will be removed -- check the menu by hand")
    sys.exit(0)

for b, t, why in remove:
    print(f"  remove  : [{why}] {t[:88]}")

if not remove:
    print("  nothing to remove")
    sys.exit(0)

if mode != '--apply':
    print(f"  dry run: {len(remove)} entries would be removed, no writes")
    sys.exit(0)

bak = cfg + '.a16prune'
shutil.copy2(cfg, bak)
drop = set()
for _blk, _title, _why in remove:
    drop.update(range(_blk[0], _blk[1]))
open(cfg, 'w').write('\n'.join(l for i, l in enumerate(lines) if i not in drop))
print(f"  wrote {cfg}  (backup {bak})")
rc = subprocess.run(['grub-script-check', cfg]).returncode
print(f"  grub-script-check: {'PASS' if rc == 0 else 'FAIL -- restore ' + bak}")
print(f"  menu now: {sum(1 for l in open(cfg) if l.startswith('menuentry'))} entries")
PY
