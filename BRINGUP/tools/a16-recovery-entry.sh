#!/bin/bash
# a16-recovery-entry.sh -- add two entries that always get you in, and retire the failsafe
# that hangs the boot.
#
#   report:  sudo bash ~/a16-payload/camera/a16-recovery-entry.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-recovery-entry.sh --apply
#
# Adds to the ubuntu menu and its EFI/BOOT fallback copy:
#   1. "recovery - t2, command line, wifi": the t2 kernel with systemd.unit=multi-user.target.
#      The normal display path is left ALONE, so the panel works and the text console is on
#      it; NetworkManager is a service, so wifi comes up.  This is the one to use when the
#      desktop or the login session is broken -- log in on tty0 or over ssh and fix it.
#   2. "failsafe - t2, panel to firmware framebuffer": same, but with ONLY msm blacklisted,
#      so Linux never takes the panel and the firmware's picture stays.  The old failsafe
#      blacklisted dispcc/gpucc/videocc/phy_qcom_edp/panel too, which are clock-controller
#      and GDSC providers the rest of the boot needs: that is why it died before systemd.
#
# Retires the old full-blacklist failsafe (archived), and makes the EFI/BOOT fallback default
# to the recovery entry: a visible, safe landing instead of a hang.

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCH=/home/jc/a16-payload/camera/grub-archive/$STAMP
KVER=7.3.0-rc5-next-20261002-t2
DTB=/boot/glymur-a16-7.3.0-rc5-next-20261002-t2.dtb
UUID=f8e005e9-414c-4c8e-ad68-d1e9fdc208bc
COMMON="root=UUID=$UUID ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7"
RECOVERY='A16: recovery - t2, command line, wifi'
FAILSAFE='A16: failsafe - t2, panel left to firmware framebuffer (msm blacklisted)'
OLD_FAILSAFE_RE='^(?:\[\d+\]\s*)?A16: next 7\.3 \+ glymur DTB, panel left to firmware'
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-recovery-entry ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode: $([ "$APPLY" = 1 ] && echo APPLY || echo 'report only')"
[ -f "/boot/vmlinuz-$KVER" ] && [ -f "/boot/initrd.img-$KVER" ] && [ -f "$DTB" ] || { echo "  [fail] kernel/initramfs/dtb missing"; exit 1; }
export KVER DTB COMMON RECOVERY FAILSAFE OLD_FAILSAFE_RE ARCH

for m in $MENUS; do
	echo
	echo "--- $m"
	[ -f "$m" ] || { echo "  (absent)"; continue; }
	python3 - "$m" "$APPLY" <<'PY'
import os, re, sys, shutil
menu, apply_ = sys.argv[1], sys.argv[2] == "1"
kver, dtb, common = os.environ['KVER'], os.environ['DTB'], os.environ['COMMON']
rec, fs, oldre, arch = os.environ['RECOVERY'], os.environ['FAILSAFE'], os.environ['OLD_FAILSAFE_RE'], os.environ['ARCH']
s = open(menu).read()
ent = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
names = [b.group(1) for b in ent]
old = [b for b in ent if re.match(oldre, b.group(1))]

def block(title, cmdline):
    return (f'# added by a16-recovery-entry.sh\nmenuentry "{title}" {{\n'
            f'    search --no-floppy --fs-uuid --set=root {os.environ.get("UUID","")}\n'
            f'    if [ -f /boot/vmlinuz-{kver} -a -f /boot/initrd.img-{kver} ]; then\n'
            f'        insmod fdt\n        insmod gzio\n'
            f'        linux /boot/vmlinuz-{kver} {common} {cmdline}\n'
            f'        devicetree {dtb}\n'
            f'        initrd /boot/initrd.img-{kver}\n        boot\n    fi\n'
            f'    echo "  kernel or initramfs missing"\n    sleep 20\n'
            f'    configfile $prefix/grub.cfg\n}}\n')

sys.stderr.write(f"      entries {len(names)}; old failsafe present: {bool(old)}; recovery present: {rec in names}; failsafe present: {fs in names}\n")
if not apply_:
    print("      [check] would add the recovery and failsafe entries, retire the old failsafe,")
    print("              and point this menu's default at the recovery entry (BOOT) / leave t2 (ubuntu)")
    raise SystemExit

os.makedirs(arch, exist_ok=True)
open(os.path.join(arch, os.path.basename(os.path.dirname(menu)) + '.grub.cfg'), 'w').write(s)
with open(os.path.join(arch, 'retired-menuentries.txt'), 'a') as f:
    for b in old:
        f.write(f"# from {menu}\n{b.group(0)}\n\n")

out = s
for b in old:
    for cand in (b.group(0) + "\n", b.group(0)):
        if cand in out:
            out = out.replace(cand, "", 1); break
anchor = re.search(r'^menuentry\s+"A16: linux-next 7\.3\.0-rc5-next-20261002-t2"', out, re.M)
add = ""
if rec not in names:  add += block(rec, 'systemd.unit=multi-user.target') + "\n"
if fs not in names:   add += block(fs, 'modprobe.blacklist=msm module_blacklist=msm') + "\n"
out = (out[:anchor.start()] + add + out[anchor.start():]) if anchor else (out.rstrip() + "\n\n" + add)
# the BOOT fallback should land on recovery (visible, safe); ubuntu keeps the plain t2
want = 'A16: linux-next 7.3.0-rc5-next-20261002-t2' if 'vmlinuz-7.3.0-rc5-next-20261002-t2' in s and 'A16: linux-next' in s else rec
out = re.sub(r'^set default=.*$', f'set default="{want}"', out, count=1, flags=re.M)
out = re.sub(r'\n{3,}', '\n\n', out)
open(menu + '.new', 'w').write(out); os.replace(menu + '.new', menu)

cur = open(menu).read()
after = re.findall(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M)
d = re.search(r'^set default=(.*)$', cur, re.M).group(1).strip().strip('"')
tgt = [b for t, b in after if t == d]
k = re.search(r'^\s*linux\s+(\S+)', tgt[0], re.M).group(1) if tgt else '?'
broken = [t for t, b in after if (mm := re.search(r'^\s*linux\s+(\S+)', b, re.M)) and mm.group(1).startswith('/boot') and not os.path.exists(mm.group(1))]
print(f"      -> {len(after)} entries; default '{d[:44]}' -> {os.path.basename(k)}; missing-kernel: {len(broken)}")
PY
done

echo
if [ "$APPLY" = 1 ]; then
	echo "done.  Pre-change copies of the menus: $ARCH"
	echo
	echo "In the recovery entry: log in on the panel's console (tty0) or over ssh.  NetworkManager"
	echo "is a service, so wifi comes up by itself; if the ath12k has wedged, run: sudo reload_wifi"
else
	echo "Nothing changed.  Run with --apply."
fi
