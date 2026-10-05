#!/bin/bash
# a16-camera3-entry.sh -- install the claim-only camera DTB and point ONLY the camera entry at it.
#
#   report:  sudo bash ~/a16-payload/camera/a16-camera3-entry.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-camera3-entry.sh --apply
#
# The one change from camera1: the sensor's dovdd-supply moves from vreg_l2b_e0 to a rail nothing
# else in the tree references (vreg_l10b_e0, 1.8 V -- a dovdd-shaped voltage).  No regulator
# voltage is touched anywhere: a claimed rail keeps its voltage, which is what makes this safe.
# Changing a shared rail's voltage is what took the panel down once; claiming one cannot.
#
# Only the entry titled "A16: camera step 1..." has its devicetree line replaced.  The script
# prints every other entry's devicetree beforehand and re-checks them afterwards, so "the entry
# you normally boot is untouched" is something you can see in the output rather than take on trust.

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCH=/home/jc/a16-payload/camera/grub-archive/$STAMP
SRC=/home/jc/a16-payload/camera/glymur-a16-camera3.dtb
DST=/boot/glymur-a16-camera3.dtb
MENU=/boot/efi/EFI/ubuntu/grub.cfg
CAMTITLE='A16: camera step 1'
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-camera3-entry ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode: $([ "$APPLY" = 1 ] && echo APPLY || echo 'report only')"
[ -f "$SRC" ] || { echo "  [fail] $SRC is missing"; exit 1; }
echo "  source DTB : $SRC ($(stat -c%s $SRC) bytes, sha256 $(sha256sum $SRC | cut -c1-16)…)"
echo "  installs to: $DST"
echo

python3 - "$MENU" "$CAMTITLE" "$DST" "$APPLY" "$SRC" "$ARCH" <<'PY'
import os, re, shutil, sys
menu, camtitle, dst, apply_, src, arch = sys.argv[1:7]
apply_ = apply_ == "1"
s = open(menu).read()
ent = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))

def dt_of(body):
    m = re.search(r'^\s*devicetree\s+(\S+)', body, re.M)
    return m.group(1) if m else '(none)'

print("  devicetree lines before:")
for b in ent:
    print(f"     {b.group(1)[:52]:52s} {dt_of(b.group(2))}")
cam = [b for b in ent if b.group(1).startswith(camtitle)]
if len(cam) != 1:
    print(f"  [fail] expected exactly one '{camtitle}' entry, found {len(cam)}"); raise SystemExit(1)
cam = cam[0]
before = {b.group(1): dt_of(b.group(2)) for b in ent}
if not apply_:
    print(f"\n  [check] would point '{cam.group(1)}' at {dst} and leave the other {len(ent)-1} entries alone")
    raise SystemExit(0)
os.makedirs(arch, exist_ok=True)
open(os.path.join(arch, 'ubuntu.grub.cfg'), 'w').write(s)
new_body = re.sub(r'^(\s*devicetree\s+)\S+', lambda m: m.group(1) + dst, cam.group(2), count=1, flags=re.M)
out = s[:cam.start(2)] + new_body + s[cam.end(2):]
open(menu + '.new', 'w').write(out); os.replace(menu + '.new', menu)

cur = open(menu).read()
ent2 = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', cur, re.S | re.M))
after = {b.group(1): dt_of(b.group(2)) for b in ent2}
print("\n  devicetree lines after:")
for b in ent2:
    mark = " <== changed" if after[b.group(1)] != before.get(b.group(1)) else ""
    print(f"     {b.group(1)[:52]:52s} {after[b.group(1)]}{mark}")
others = [k for k in before if not k.startswith(camtitle) and before[k] != after.get(k)]
print(f"\n  entries changed: {len([k for k in after if before.get(k) != after[k]])} (must be 1)")
print(f"  non-camera entries altered: {len(others)} (must be 0)")
print(f"  camera entry now: {after.get(cam.group(1))}")
PY

echo
if [ "$APPLY" = 1 ]; then
	install -m 644 "$SRC" "$DST" && echo "  installed $DST (sha256 $(sha256sum $DST | cut -c1-16)…)"
	echo "  menu backed up: $ARCH/ubuntu.grub.cfg"
	echo
	echo "Now boot 'A16: camera step 1' and check whether the sensor ACKs:"
	echo "   sudo dmesg | grep -iE 'ov08x40|cci|csiphy' | tail -20"
	echo "   sudo bash ~/a16-payload/camera/a16-camera-report.sh"
	echo "If it does not, nothing was harmed: no voltage changed, and the usual entry never moved."
else
	echo "Nothing changed.  Run with --apply."
fi
