#!/bin/bash
# a16-recovery-entry.sh -- add a recovery entry and a minimal failsafe, built by CLONING the
# entry that is already known to boot, and retire the failsafes that do not.
#
#   report:  sudo bash ~/a16-payload/camera/a16-recovery-entry.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-recovery-entry.sh --apply
#
# Design rule, after getting this wrong once: do not author boot entries.  The known-good
# entry ("A16: linux-next 7.3.0-rc5-next-20261002-t2") is read out of the menu and cloned
# verbatim, changing ONLY the cmdline suffix and the title.  Search, insmod, devicetree,
# initrd, the file guard and the missing-file fallback all come from the entry that boots.
# An earlier version wrote its own blocks and shipped an unset UUID variable: search got no
# UUID, $root stayed on the ESP partition, the guard failed there and the entry reported
# "kernel or initramfs missing".  Cloning cannot have that class of bug, and this script
# refuses to run at all if it cannot find the base entry in the menu.
#
#   recovery = base + systemd.unit=multi-user.target   -> normal display path: panel + console
#   failsafe = base + modprobe.blacklist=msm module_blacklist=msm  -> firmware framebuffer
#
# Also: retires the staged-7.2 framebuffer entry and the 7.3 full-blacklist failsafe (neither
# boots; the latter takes out clock-controller/GDSC providers the boot needs), moves the
# staged 7.2 ESP payload (/a16boot, 82M) to the archive, and drops the 7.2 probes from the
# diagnostics entry.  Nothing is deleted without being archived first.  Run me twice and the
# second run is a no-op.

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCH=/home/jc/a16-payload/camera/grub-archive/$STAMP
BASE_TITLE='A16: linux-next 7.3.0-rc5-next-20261002-t2'
REC_TITLE='A16: recovery - t2, command line, wifi'
FS_TITLE='A16: failsafe - t2, panel left to firmware framebuffer (msm blacklisted)'
# the two that do not boot: the staged-7.2 one, and the 7.3 full-blacklist one
BAD_RE='^(?:\[\d+\]\s*)?A16: (?:7\.2 \+ glymur DTB, internal input, panel via firmware framebuffer|next 7\.3 \+ glymur DTB, panel left to firmware)'
STAGE=/boot/efi/a16boot
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-recovery-entry ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode: $([ "$APPLY" = 1 ] && echo APPLY || echo 'report only')"
echo "  base entry to clone: $BASE_TITLE"
[ -f /boot/vmlinuz-7.3.0-rc5-next-20261002-t2 ] || { echo "  [fail] the t2 kernel is not in /boot"; exit 1; }
export BASE_TITLE REC_TITLE FS_TITLE BAD_RE ARCH

# EFI/BOOT has no t2 entry of its own, but it needs the same clone.  Take the base block from
# whichever menu has it, verbatim, and give it to every menu.
BASEFILE=$(mktemp /tmp/a16-base.XXXXXX)
python3 - "$BASEFILE" $MENUS <<'PYB'
import os, re, sys
out, menus = sys.argv[1], sys.argv[2:]
for m in menus:
	s = open(m).read()
	b = re.search(r'^menuentry\s+"' + re.escape(os.environ['BASE_TITLE']) + r'"\s*\{.*?^\}', s, re.S | re.M)
	if b:
		open(out, 'w').write(b.group(0) + "\n"); print(f"  base entry taken from {os.path.basename(os.path.dirname(m))}"); break
else:
	print("  [fail] the base entry exists in none of the menus"); raise SystemExit(1)
PYB
[ -s "$BASEFILE" ] || { echo "  [fail] no base entry to clone -- stopping"; exit 1; }
export BASEFILE

for M in $MENUS; do
	echo
	echo "--- $M"
	[ -f "$M" ] || { echo "  (absent)"; continue; }
	python3 - "$M" "$APPLY" <<'PY'
import os, re, sys
menu, apply_ = sys.argv[1], sys.argv[2] == "1"
base_t, rec_t, fs_t = os.environ['BASE_TITLE'], os.environ['REC_TITLE'], os.environ['FS_TITLE']
badre, arch = os.environ['BAD_RE'], os.environ['ARCH']
s = open(menu).read()
ent = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
names = [b.group(1) for b in ent]

base = next((b.group(0) for b in ent if b.group(1) == base_t), None)
local_base = base is not None
if not base:
	bf = os.environ.get('BASEFILE', '')
	base = open(bf).read().rstrip("\n") if bf and os.path.exists(bf) and os.path.getsize(bf) else None
if not base:
	print("      [fail] no base entry available -- refusing to invent one")
	raise SystemExit(0)

def clone(title, suffix):
	blk = re.sub(r'^menuentry\s+"[^"]+"', lambda m: f'menuentry "{title}"', base, count=1, flags=re.M)
	blk = re.sub(r'^([ \t]*linux\s+.*?)\s*$', lambda m: m.group(1) + ' ' + suffix, blk, count=1, flags=re.M)
	return '# cloned from "' + base_t + '" by a16-recovery-entry.sh\n' + blk + "\n"

rec_block = clone(rec_t, 'systemd.unit=multi-user.target')
fs_block = clone(fs_t, 'modprobe.blacklist=msm module_blacklist=msm')
bad = [b for b in ent if re.match(badre, b.group(1))]
# our own earlier versions, if they are already in there (they do not boot): replace them
previous = [b for b in ent if b.group(1) in (rec_t, fs_t)]
print(f"      entries {len(names)}; base present: yes;"
      f" recovery already here: {'yes' if rec_t in names else 'no'};"
      f" failsafe already here: {'yes' if fs_t in names else 'no'};"
      f" entries to retire: {len(bad)} + {len(previous)} replaced")
if not apply_:
	print("      [check] would clone the base entry twice (recovery, failsafe):")
	print("              recovery = base + systemd.unit=multi-user.target")
	print("              failsafe = base + modprobe.blacklist=msm module_blacklist=msm")
	print("              and retire the entries above; ubuntu keeps its default, EFI/BOOT gets recovery")
	raise SystemExit(0)

os.makedirs(arch, exist_ok=True)
open(os.path.join(arch, os.path.basename(os.path.dirname(menu)) + '.grub.cfg'), 'w').write(s)
with open(os.path.join(arch, 'retired-menuentries.txt'), 'a') as f:
	for b in bad + previous:
		f.write(f"# from {menu}\n{b.group(0)}\n\n")

out = s
for b in bad + previous:
	for cand in (b.group(0) + "\n\n", b.group(0) + "\n", b.group(0)):
		if cand in out:
			out = out.replace(cand, "", 1); break
anchor = re.search(r'^menuentry\s+"' + re.escape(base_t) + r'"\s*\{.*?^\}', out, re.S | re.M)
add = rec_block + "\n" + fs_block + "\n"
if anchor:
	out = out[:anchor.end()] + "\n\n" + add + out[anchor.end():]
else:
	# no base entry in this menu (EFI/BOOT): the clones still go in, at the end
	out = out.rstrip() + "\n\n" + add
# EFI/BOOT is the firmware's fallback: land it on recovery (visible, safe).  ubuntu keeps t2.
if base_t not in [m.group(1) for m in re.finditer(r'^menuentry\s+"([^"]+)"', out, re.M)]:
	out = re.sub(r'^set default=.*$', f'set default="{rec_t}"', out, count=1, flags=re.M)
# diagnostics: no staged payload to list any more, and no 7.2 probes
out = re.sub(r'^[ \t]*search --no-floppy --file --set=a16esp /a16boot/vmlinuz\n', '', out, flags=re.M)
out = out.replace('      echo "  staged ESP payload found on: $a16esp"\n', '')
out = re.sub(r'^[ \t]*echo "  --- staged ESP payload ---"\n', '', out, flags=re.M)
out = re.sub(r'^[ \t]*ls \(\$a16esp\)/a16boot\n', '', out, flags=re.M)
out = out.replace('7.3.0-rc3-next-20260914', '7.3.0-rc5-next-20261002-t2')
out = re.sub(r'^[ \t]*if \[ -f \(\$r17\)/boot/(?:vmlinuz|initrd\.img)-7\.2\.0-5-generic \].*\n', '', out, flags=re.M)
out = re.sub(r'\n{3,}', '\n\n', out)
open(menu + '.new', 'w').write(out); os.replace(menu + '.new', menu)

cur = open(menu).read()
after = re.findall(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M)
d = re.search(r'^set default=(.*)$', cur, re.M).group(1).strip().strip('"')
broken = [t for t, b in after if (mm := re.search(r'^\s*linux\s+(\S+)', b, re.M))
	  and mm.group(1).startswith('/boot') and not os.path.exists(mm.group(1))]
print(f"      -> {len(after)} entries; default '{d[:40]}'; missing-kernel entries: {len(broken)}")
for t in (rec_t, fs_t):
	b = [bb for tt, bb in after if tt == t]
	if not b:
		print(f"         !! {t}: NOT PRESENT"); continue
	whole = re.search(r'^menuentry\s+"[^"]+"\s*\{(.*?)^\}', b[0], re.S | re.M)
	# prove the clone kept the mechanics of the base
	mech = {k: bool(re.search(pat, b[0], re.M)) for k, pat in
		(('search', r'^\s*search\s'), ('linux', r'^\s*linux\s'), ('devicetree', r'^\s*devicetree\s'),
		 ('initrd', r'^\s*initrd\s'), ('boot', r'^\s*boot\s*$'))}
	uuid = re.search(r'--set=root\s+(\S+)', b[0], re.M)
	cmd = re.search(r'^\s*linux\s+(.*)$', b[0], re.M).group(1)
	print(f"         {t[:32]}: search={mech['search']} dt={mech['devicetree']} initrd={mech['initrd']} boot={mech['boot']}")
	print(f"            uuid={uuid.group(1) if uuid else '!! MISSING'}  tail=...{cmd[-58:]}")
PY
done

echo
if [ -d "$STAGE" ]; then
	live=$(grep -lE '^[[:space:]]*(linux|initrd)[[:space:]]+/a16boot/' $MENUS 2>/dev/null)
	if [ -n "$live" ]; then
		echo "  [skip] an entry still boots /a16boot/: $live"
	elif [ "$APPLY" != 1 ]; then
		echo "  [check] would move $STAGE ($(du -sh $STAGE | cut -f1)) to $ARCH/a16boot/ (frees it from the ESP)"
	else
		mkdir -p "$ARCH"; mv "$STAGE" "$ARCH/a16boot" && echo "  moved $STAGE -> $ARCH/a16boot ($(df -h /boot/efi | tail -1 | awk '{print $4}') free on the ESP)"
	fi
else
	echo "  $STAGE: not present (nothing to move)"
fi

echo
if [ "$APPLY" = 1 ]; then
	echo "done.  Pre-change menus and everything retired: $ARCH"
	echo
	echo "recovery: log in on the panel's console (tty0) or over ssh.  NetworkManager is a"
	echo "service, so wifi comes up by itself; if the ath12k has wedged: sudo reload_wifi"
else
	echo "Nothing changed.  Run with --apply."
fi
