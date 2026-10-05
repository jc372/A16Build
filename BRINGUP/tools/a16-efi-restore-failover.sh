#!/bin/bash
# a16-efi-restore-failover.sh -- put the 7.3 failover entry back, and take out the stale
# staged-7.2 entry that replaced it in the earlier prune (which had the two the wrong way
# round: it kept the entry that cannot boot and removed the one that works).
#
#   report:  sudo bash ~/a16-payload/camera/a16-efi-restore-failover.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-efi-restore-failover.sh --apply
#
# The entry restored is "A16: next 7.3 + glymur DTB, panel left to firmware (msm/display CCs
# blacklisted)" -- a 7.3 kernel with msm blacklisted so the panel stays on the firmware's
# framebuffer.  It is taken verbatim from the archive the prune wrote, so it is the same
# block, and its [ -f ] guard and paths are checked before it is installed.
#
# Removed: "A16: 7.2 + glymur DTB, internal input, panel via firmware framebuffer", which
# boots /a16boot/vmlinuz -- the Sep-16 staged payload, which cannot boot against today's
# root filesystem (the same reason the staged ACPI entry failed).

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCHNEW=/home/jc/a16-payload/camera/grub-archive/$STAMP
ARCHSRC=$(ls -1d /home/jc/a16-payload/camera/grub-archive/*/ 2>/dev/null | tail -1)
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-efi-restore-failover ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode        : $([ "$APPLY" = 1 ] && echo 'APPLY' || echo 'report only (--apply to change)')"
echo "  archive from: ${ARCHSRC:-NOT FOUND}"
[ -n "$ARCHSRC" ] && [ -f "$ARCHSRC/removed-menuentries.txt" ] || { echo "  [fail] no archive with removed-menuentries.txt -- cannot restore"; exit 1; }

python3 - "$ARCHSRC/removed-menuentries.txt" "$ARCHNEW" "$APPLY" $MENUS <<'PY'
import re, os, sys
archsrc, archnew, apply_ = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
menus = sys.argv[4:]
DROP_TITLE = re.compile(r'^(?:\[\d+\]\s*)?A16: 7\.2 \+ glymur DTB, internal input, panel via firmware framebuffer$')
WANT_TITLE = re.compile(r'^(?:\[\d+\]\s*)?A16: next 7\.3 \+ glymur DTB, panel left to firmware')

# the archived block, taken verbatim
src = open(archsrc).read()
blocks = [b for b in re.findall(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', src, re.S | re.M)]
want = next((b for t, b in blocks if WANT_TITLE.match(t)), None)
if not want:
    print("  [fail] the archived failover block was not found"); raise SystemExit(1)
want_title = re.sub(r'^\[\d+\]\s*', '', WANT_TITLE.search(src).group(0) if False else next(t for t, b in blocks if WANT_TITLE.match(t)))
want_block = f'# restored by a16-efi-restore-failover.sh (was removed by the prune in error)\nmenuentry "{want_title}" {{{want}}}'
print(f"  restoring: {want_title}")

for menu in menus:
    if not os.path.exists(menu):
        print(f"  --- {menu}: absent"); continue
    s = open(menu).read()
    ent = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
    drop = [b for b in ent if DROP_TITLE.match(b.group(1))]
    have = any(re.sub(r'^\[\d+\]\s*', '', t) == want_title for t, _ in
               [(b.group(1), b.group(2)) for b in ent])
    print(f"  --- {menu}")
    print(f"      entries {len(ent)}, stale 7.2 entry present: {bool(drop)}, failover present: {have}")
    if not drop and have:
        print("      [ok] already correct -- nothing to do"); continue
    if not apply_:
        print("      [check] would remove the stale 7.2 entry and add the failover entry")
        continue
    os.makedirs(archnew, exist_ok=True)
    open(os.path.join(archnew, os.path.basename(menu) + '.pre-restore'), 'w').write(s)
    out = s
    for b in drop:
        for cand in (b.group(0) + "\n", b.group(0)):
            if cand in out:
                out = out.replace(cand, "", 1); break
    if not have:
        anchor = re.search(r'^menuentry\s+"A16: linux-next 7\.3\.0-rc5-next-20261002-t2"', out, re.M)
        out = (out[:anchor.start()] + want_block + "\n\n" + out[anchor.start():]) if anchor else (out.rstrip() + "\n\n" + want_block + "\n")
    # default: the plain t2 entry where it exists, else the failover
    d = re.sub(r'^\[\d+\]\s*', '', 'A16: next 7.3 + glymur DTB, panel left to firmware (msm/display CCs blacklisted)')
    if any(re.sub(r'^\[\d+\]\s*', '', t) == 'A16: linux-next 7.3.0-rc5-next-20261002-t2' for t, _ in [(b.group(1), b.group(2)) for b in ent]):
        d = 'A16: linux-next 7.3.0-rc5-next-20261002-t2'
    out = re.sub(r'^set default=.*$', f'set default="{d}"', out, count=1, flags=re.M)
    out = re.sub(r'\n{3,}', '\n\n', out)
    open(menu + '.new', 'w').write(out); os.replace(menu + '.new', menu)
    # verify
    cur = open(menu).read()
    after = re.findall(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M)
    dd = re.search(r'^set default=(.*)$', cur, re.M).group(1).strip().strip('"')
    tgt = [b for t, b in after if t == dd]
    k = re.search(r'^\s*linux\s+(\S+)', tgt[0], re.M).group(1) if tgt else '?'
    broken = [t for t, b in after if (m := re.search(r'^\s*linux\s+(\S+)', b, re.M))
              and m.group(1).startswith('/boot') and not os.path.exists(m.group(1))]
    print(f"      -> {len(after)} entries; default '{dd[:52]}' -> {os.path.basename(k)}; missing-kernel entries: {len(broken)}")
PY

echo
if [ "$APPLY" = 1 ]; then
	echo "done.  The menus as they were before this change: $ARCHNEW"
	echo "Still on the ESP from the earlier prune: /home/jc/a16-payload/camera/grub-archive/$(basename ${ARCHSRC%/})/"
else
	echo "Nothing changed.  Run with --apply."
fi
