#!/bin/bash
# a16-efi-tidy.sh -- reduce the boot menus and the firmware boot list to what is needed.
#
#   report:  sudo bash ~/a16-payload/camera/a16-efi-tidy.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-efi-tidy.sh --apply
#
# Keeps, in the menus: the 7.3 failover that leaves the panel to the firmware (msm
# blacklisted), the normal Ubuntu entry, the diagnostics
# entry, Windows, t1 (for now), t2, t2+camera, and the ACPI dump entry.
# Removes: the dead 7.2 ACPI entry (it does not boot), the three rc3-era display variants
# whose purpose is now served by the plain t2 entry, the duplicated Bluetooth serdev test,
# and the intermediate kernels that were steps on the way to t2 (gmu1 x2, the X2 Concept
# kernel, ec1 stock).
#
# Nothing is destroyed: everything removed -- each menuentry block verbatim, all three
# menu files, and the firmware boot entries with their exact targets -- is copied into
# ~/a16-payload/camera/grub-archive/<stamp>/ with a README saying how to put it back.
#
# Firmware: keeps one Ubuntu entry and Windows, archiving the other two.

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCH=/home/jc/a16-payload/camera/grub-archive/$STAMP
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
ALLMENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
NEWLABEL='Ubuntu 7.3 linux-next'
KEEP_DEFAULT_UBUNTU='A16: linux-next 7.3.0-rc5-next-20261002-t2'
KEEP_DEFAULT_BOOT='[2] A16: next 7.3 + glymur DTB, panel left to firmware (msm/display CCs blacklisted)'
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

cat > /tmp/a16-tidy-remove.txt <<'EOS'
[0] A16: installed Ubuntu 7.2 staged on the ESP (ACPI) - picture, no internal input
[1] A16: 7.2 + glymur DTB, internal input, panel via firmware framebuffer
[3] A16: next 7.3 + glymur DTB, full display attempt (msm + panel enabled)
[4] A16: next 7.3 + DTB, msm enabled but panel PHY left unmanaged (keeps a picture, if it holds)
[8] A16: 7.3 + glymur DTB + Bluetooth serdev test (wcn7850-bt, stubbed rails)
A16: linux-next 7.3.0-rc5-next-20261002-gmu1
A16: linux-next 7.3.0-rc5-next-20261002-gmu1 + rscc (GPU test)
A16: Ubuntu Concept X2 kernel 7.3.0-15-qcom-x1e (GPU test)
[10] A16: next 7.3.0-rc5-next-20261002-ec1 stock (upstream DTB, no patches)
EOS

echo "=== a16-efi-tidy: reduce the boot menus and the firmware list ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode      : $([ "$APPLY" = 1 ] && echo 'APPLY (archives first, then changes)' || echo 'report only (--apply to change)')"
echo "  archive to: $ARCH"

echo
echo "--- firmware boot entries"
efibootmgr 2>/dev/null | grep -E '^Boot(Current|Order|000[0-9])' | sed 's/\(.*\.efi\).*/\1/' | sed 's/^/  /'
echo "  would keep  : Boot0003 (relabelled '$NEWLABEL') and Boot0002 (Windows), order 0003,0002"
echo "  would archive+remove: Boot0001 (Ubuntu -> \\EFI\\ubuntu_snapdragon\\shimaa64.efi), Boot0004 (Ubuntu Linux -> \\EFI\\ubuntu_snapdragon\\grubaa64.efi)"

for m in $MENUS; do
	echo
	echo "--- $m"
	[ -f "$m" ] || { echo "  (absent)"; continue; }
	python3 - "$m" /tmp/a16-tidy-remove.txt "$KEEP_DEFAULT_UBUNTU" "$KEEP_DEFAULT_BOOT" "$ARCH" "$APPLY" <<'PY'
import re, os, sys, shutil
menu, removelist, keep_u, keep_b, arch, apply_ = sys.argv[1:7]
apply_ = apply_ == "1"
s = open(menu).read()
blocks = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
want_remove = [l.strip() for l in open(removelist) if l.strip()]
d = re.search(r'^set default=(.*)$', s, re.M)
print(f"  default: {d.group(1).strip() if d else '-'}   entries: {len(blocks)}")

keep, drop = [], []
for b in blocks:
    (drop if b.group(1) in want_remove else keep).append(b)
for b in drop:
    k = re.search(r'^\s*linux\s+(\S+)', b.group(2), re.M)
    tag = 'was already dead' if (k and k.group(1).startswith('/boot') and not os.path.exists(k.group(1))) else 'still boots'
    print(f"    DROP  {b.group(1)[:66]:68s} ({tag})")
for b in keep:
    k = re.search(r'^\s*linux\s+(\S+)', b.group(2), re.M)
    alive = (not k) or os.path.exists(k.group(1)) or not k.group(1).startswith('/boot')
    print(f"    keep  {b.group(1)[:66]:68s} kernel={'y' if alive else 'NO'}")

if not apply_:
    raise SystemExit

os.makedirs(arch, exist_ok=True)
open(os.path.join(arch, os.path.basename(os.path.dirname(menu)) + '.grub.cfg'), 'w').write(s)
with open(os.path.join(arch, 'removed-menuentries.txt'), 'a') as f:
    for b in drop:
        f.write(f"# from {menu}\n{b.group(0)}\n\n")

out = s
for b in drop:
    for cand in (b.group(0) + "\n", b.group(0)):
        if cand in out:
            out = out.replace(cand, "", 1)
            break
out = re.sub(r'\n{3,}', '\n\n', out)
# keep t1 reachable: its only entry lives in the snapdragon menu, whose firmware entry we
# remove, so bring the block over into this menu before that happens
if menu.endswith('ubuntu/grub.cfg'):
    t1title = 'A16: linux-next 7.3.0-rc5-next-20261002-t1'
    if t1title not in [x.group(1) for x in blocks]:
        snap = '/boot/efi/EFI/ubuntu_snapdragon/grub.cfg'
        if os.path.exists(snap):
            sb = re.search(r'^menuentry\s+"' + re.escape(t1title) + r'"\s*\{(.*?)^\}', open(snap).read(), re.S | re.M)
            if sb:
                add = f'# brought over by a16-efi-tidy.sh from the snapdragon menu\nmenuentry "{t1title}" {{{sb.group(1)}}}\n'
                # place it just before the t2 entry so the order reads t1 then t2
                anchor = re.search(r'^menuentry\s+"A16: linux-next 7\.3\.0-rc5-next-20261002-t2"\s*\{', out, re.M)
                out = (out[:anchor.start()] + add + out[anchor.start():]) if anchor else (out + "\n" + add)
                print(f"    + carried the t1 entry over from the snapdragon menu")

# the [N] prefixes are the menu's old numbering; entries are named now, not numbered
out = re.sub(r'^menuentry\s+"\[\d+\]\s*', 'menuentry "', out, flags=re.M)
print("    -> stripped the [N] prefixes from the entry titles")

# the default must still name an entry that survives
want = keep_u if menu.endswith('ubuntu/grub.cfg') else keep_b
want = re.sub(r'^\[\d+\]\s*', '', want)
if any(re.sub(r'^\[\d+\]\s*', '', t) == want for t, _ in [(x.group(1), x.group(2)) for x in keep]):
    out = re.sub(r'^set default=.*$', f'set default="{want}"', out, count=1, flags=re.M)
    print(f"    -> default set to '{want[:60]}'")
else:
    first = re.sub(r'^\[\d+\]\s*', '', keep[0].group(1)) if keep else None
    if first:
        out = re.sub(r'^set default=.*$', f'set default="{first}"', out, count=1, flags=re.M)
        print(f"    -> default set to the first surviving entry '{first[:56]}'")
open(menu + '.new', 'w').write(out)
os.replace(menu + '.new', menu)

# verify
cur = open(menu).read()
after = re.findall(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M)
dd = re.search(r'^set default=(.*)$', cur, re.M).group(1).strip().strip('"')
tgt = [b for t, b in after if t == dd] or ([after[int(dd)][1]] if dd.isdigit() and int(dd) < len(after) else [])
kk = re.search(r'^\s*linux\s+(\S+)', tgt[0], re.M).group(1) if tgt else '?'
print(f"    entries now: {len(after)}   default -> {os.path.basename(kk)}   exists: {os.path.exists(kk) if kk.startswith('/boot') else 'n/a'}")
broken = []
for t, b in after:
    m = re.search(r'^\s*linux\s+(\S+)', b, re.M)
    if m and m.group(1).startswith('/boot') and not os.path.exists(m.group(1)):
        broken.append(t[:50])
print(f"    entries still naming a missing kernel: {len(broken)}" + (f" -> {broken}" if broken else ""))
PY
done

if [ "$APPLY" = 1 ]; then
	echo
	echo "--- firmware"
	efibootmgr -v > "$ARCH/firmware-bootentries.txt" 2>/dev/null && echo "  archived: $ARCH/firmware-bootentries.txt"
	cp -f /boot/efi/EFI/ubuntu_snapdragon/grub.cfg "$ARCH/ubuntu_snapdragon.grub.cfg" 2>/dev/null
	efibootmgr -b 0001 -B >/dev/null 2>&1 && echo "  removed Boot0001"
	efibootmgr -b 0004 -B >/dev/null 2>&1 && echo "  removed Boot0004"
	efibootmgr -b 0003 -L "$NEWLABEL" >/dev/null 2>&1 && echo "  relabelled Boot0003 -> $NEWLABEL"
	efibootmgr -o 0003,0002 >/dev/null 2>&1 && echo "  boot order set to 0003,0002"
	efibootmgr 2>/dev/null | grep -E '^Boot(Current|Order|000[0-9])' | sed 's/\(.*\.efi\).*/\1/' | sed 's/^/  /'
fi

if [ "$APPLY" = 1 ]; then
	cat > "$ARCH/README.md" <<EOF
# archived $(date)

Everything removed from the boot path on this run, so it can be put back.

- removed-menuentries.txt : the menuentry blocks that were deleted, verbatim, from each menu
- */grub.cfg               : the complete menu files as they were before this run
- ubuntu_snapdragon.grub.cfg : the snapdragon menu (its firmware entries were removed)
- firmware-bootentries.txt : efibootmgr -v output before the firmware entries were removed

To restore a menuentry: paste its block back into the menu file it came from.
To restore a firmware entry, recreate it from its target in firmware-bootentries.txt, e.g.:
  efibootmgr -c -d /dev/nvme0n1 -p 12 -L "Ubuntu" -l '\\EFI\\ubuntu_snapdragon\\shimaa64.efi'
(device and partition from the HD(...) field: here HD(12,...) on the ESP.)

The menu files themselves are also copied beside each file as grub.cfg.bak-* by the tooling.
EOF
	echo "  archived everything to: $ARCH"
else
	echo
	echo "Nothing was changed.  Run with --apply to archive and then remove."
fi
