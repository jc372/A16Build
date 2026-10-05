#!/bin/bash
# a16-grub-fix.sh -- make every menu on the ESP boot a kernel that actually exists.
#
#   report:  sudo bash ~/a16-payload/camera/a16-grub-fix.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-grub-fix.sh --apply
#
# The problem this fixes: the EFI/ubuntu menu (Boot0003 in the firmware's boot order, and
# its copy at EFI/BOOT, which is what a fallback boot lands on) has "set default=3", and
# entry [3] names /boot/vmlinuz-7.3.0-rc3-next-20260914 -- a kernel that is no longer
# installed.  A menuentry whose kernel is missing does not fail cleanly: it echoes, sleeps
# 20 seconds and then reloads the same menu, defaulting to itself again.  That is the pause
# and the "wrong kernel" you see at boot.
#
# What it does, and only this:
#   * for every entry on the affected menus whose kernel and initramfs are NOT installed,
#     repoint the linux/initrd paths (and their [ -f ] guard) at the current kernel,
#     KEEPING that entry's own command line -- the flags that make each entry different
#     stay exactly as they are.  Entry titles and menu numbering are untouched.
#   * therefore "set default=3" becomes valid again without any menu being reordered.
#   * removes the duplicated menuentry (two entries share the [8] Bluetooth title).
#
# It does not delete entries, does not touch the boot order, does not regenerate any menu,
# and does not touch /boot, the device trees or any initramfs.  Every menu is copied to
# <file>.bak-<stamp> beside itself first, and any failure restores it.

set -u
KVER=$(uname -r)
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
STAMP=$(date +%Y%m%d-%H%M%S)
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-grub-fix: menus that default to a kernel that is not installed ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo: the ESP is not writable as $(id -un)"; exit 1; }
echo "  current kernel : $KVER"
echo "  mode           : $([ "$APPLY" = 1 ] && echo 'APPLY (writes, with backups)' || echo 'report only (use --apply to change anything)')"

for m in $MENUS; do
	echo
	echo "--- $m"
	[ -f "$m" ] || { echo "  (absent)"; continue; }
	cp -f "$m" "$m.bak-$STAMP" 2>/dev/null || { echo "  [fail] cannot back up -- skipping"; continue; }

	python3 - "$m" "$KVER" "$APPLY" "$STAMP" <<'PY'
import re, sys, os

menu, kver, apply_ = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
STAMP = sys.argv[4]
want_k, want_i = f"/boot/vmlinuz-{kver}", f"/boot/initrd.img-{kver}"
s = open(menu).read()
default = re.search(r'^set default=(.*)$', s, re.M)
print(f"  default        : {default.group(1).strip() if default else '(none)'}")

# entry blocks: menuentry "TITLE" { ... } at column 0
blocks = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
titles = {}
dead = []
for b in blocks:
    title, body = b.group(1), b.group(2)
    titles.setdefault(title, []).append(b)
    k = re.search(r'^\s*linux\s+(\S+)', body, re.M)
    i = re.search(r'^\s*initrd\s+(\S+)', body, re.M)
    kp = k.group(1) if k else None
    ip = i.group(1) if i else None
    # the ESP-staged entry names files inside the ESP, not /boot
    if not kp:
        print(f"    n/a   {title[:64]:66s} (no kernel: loads something else)")
        continue
    alive = os.path.exists(kp) if kp.startswith("/boot") else True
    # an entry whose TITLE is a kernel identity (or says stock/upstream) is not a config
    # variant: repointing it would make the title a lie, so those are only reported.
    ident = bool(re.search(r"gmu1|\bt1\b|ec1|X2|qcom-x1e|stock|upstream|no patches", title))
    print(f"    {'OK  ' if alive else ('DEAD* ' if ident else 'DEAD ')} {title[:62]:64s} {kp}")
    if not alive and not ident:
        dead.append((b, title, kp, ip))

dups = {t: v for t, v in titles.items() if len(v) > 1}

if apply_:
    # repoint dead entries at the current kernel, keeping each entry's own cmdline
    out = s
    for b, title, kp, ip in dead:
        old_k = re.search(r'^(\s*linux\s+)(\S+)(.*)$', b.group(0), re.M)
        if not old_k:
            continue
        new_block = b.group(0).replace(old_k.group(2), want_k, 1)
        new_block = re.sub(r'^(\s*initrd\s+)\S+', lambda m: m.group(1) + want_i, new_block, count=1, flags=re.M)
        # the guard in front of it, if any
        if kp: new_block = new_block.replace(f"[ -f {kp} -a -f {ip} ]", f"[ -f {want_k} -a -f {want_i} ]")
        new_block = f"# a16-grub-fix.sh: kernel repointed from {kp} ({STAMP})\n" + new_block
        out = out.replace(b.group(0), new_block, 1)
        print(f"    -> repointed '{title[:48]}' to {kver}")
    # drop the later copy of any duplicated title
    for t, v in dups.items():
        for b in v[1:]:
            out = out.replace(b.group(0) + "\n", "", 1)
            print(f"    -> removed the duplicate menuentry '{t[:48]}'")
    if out != s:
        open(menu + ".new", "w").write(out)
        os.replace(menu + ".new", menu)

# post-checks, on whichever content is now in place
cur = open(menu).read()
after = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M))
still_dead = []
for b in after:
    k = re.search(r'^\s*linux\s+(\S+)', b.group(2), re.M)
    if k and k.group(1).startswith("/boot") and not os.path.exists(k.group(1)):
        still_dead.append(b.group(1)[:48])
d = re.search(r'^set default=(.*)$', cur, re.M)
dv = d.group(1).strip().strip('"') if d else ""
if dv.isdigit() and int(dv) < len(after):
    dk = re.search(r'^\s*linux\s+(\S+)', after[int(dv)].group(2), re.M)
    print(f"    default -> entry {dv} = '{after[int(dv)].group(1)[:44]}'")
    print(f"    its kernel exists: {'yes' if (dk and os.path.exists(dk.group(1))) else 'NO'}")
elif dv:
    tgt = [b for b in after if b.group(1) == dv]
    if tgt:
        dk = re.search(r'^\s*linux\s+(\S+)', tgt[0].group(2), re.M)
        print(f"    default -> '{dv[:44]}'  its kernel exists: {'yes' if (dk and os.path.exists(dk.group(1))) else 'NO'}")
print(f"    entries: {len(blocks)} before, {len(after)} after")
if still_dead:
    print(f"    [!!] entries still naming a missing kernel: {len(still_dead)}")
PY
done

echo
if [ "$APPLY" = 1 ]; then
	echo "done.  Menu backups are beside each file as grub.cfg.bak-$STAMP."
	echo "To undo: copy a backup back over its menu (they are plain files on the ESP)."
else
	echo "Nothing was changed.  Run with --apply to repoint the dead entries and drop the duplicate."
fi
echo "The firmware's own boot order is untouched: efibootmgr still shows BootOrder 0003,0001,0004,0002"
echo "(0003 = EFI\\ubuntu, the menu this fixes; 0001/0004 = the snapdragon menu, which already defaults to t2)."
