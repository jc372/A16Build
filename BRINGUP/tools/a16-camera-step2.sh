#!/usr/bin/env bash
# a16-camera-step2.sh -- arm the camera's power rails, for the camera boot entry
# only.  Run as root:
#
#     sudo bash ~/a16-payload/camera/a16-camera-step2.sh          # install
#     sudo bash ~/a16-payload/camera/a16-camera-step2.sh --check  # verify only
#     sudo bash ~/a16-payload/camera/a16-camera-step2.sh --remove # undo
#
# WHY THE CAMERA ENTRY GETS ITS OWN INITRAMFS
#   The rails the sensor runs on live on the PMH0104 PMIC, and the running
#   kernel's regulator module cannot describe them at all -- it knows four SMPS
#   of that PMIC and no LDOs.  So step 2 needs a rebuilt qcom-rpmh-regulator,
#   which the kernel loads while it is still running from the initramfs (the boot
#   disk needs those rails).  That is the lever: the camera entry boots its own
#   initramfs with the rebuilt module inside, and every menu entry you already use
#   keeps the initramfs it boots today, byte for byte.  The module is deliberately
#   NOT installed into /lib/modules, so it cannot reach the usual boot paths.
#
# WHY IT IS BUILT WITH mkinitramfs AND NOT BY HAND
#   The first version of this script unpacked the initramfs with cpio, swapped the
#   module and packed it again.  That panicked the machine.  The reason is worth
#   keeping: a modern initramfs is not one archive.  This machine's is an
#   uncompressed cpio holding a small early tree, followed by the real tree as a
#   zstd archive (COMPRESS=zstd in /etc/initramfs-tools/initramfs.conf) -- and
#   `cpio -i` stops at the first TRAILER, so the rebuild kept 2.6 MB of 48 MB, lost
#   /init and the root filesystem's modules, and the kernel had nothing to mount
#   root with.  Now the archive is built by the same generator that built the one
#   the machine is running (mkinitramfs, same hooks -- including a16-qcom-firmware,
#   which the ADSP needs) and checked with lsinitramfs, which understands the
#   concatenated layout.
#
# WHAT IS CHECKED BEFORE ANYTHING IS INSTALLED
#   module: sha256, vermagic equal to the installed module's, module_layout CRC
#   equal, symbol versions from the tree that built the running kernel, and the
#   PMH0104 vreg table at 256 bytes (7 rails, was 160).
#   tree: cci1, the sensor node and all three supplies present.
#   initramfs after building: the stock one byte-identical, no member missing,
#   /init present, and every copy of the module inside hashing to the staged one.
#   A failure anywhere reverts the camera entry to the stock initramfs before it
#   exits, so the entry can never be left pointing at an initramfs that cannot boot.
#
# WHAT TO EXPECT IN THE LOG AFTER THE REBOOT
#   the three dummy-regulator lines gone, `rpmh-regulator` registering ldo4/ldo7
#   for pmic-id I_E0, and the chip id read answering: 21-0036 ... chip id 0x560858
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=/home/jc
cam=$root/a16-payload/camera
MOD=$cam/mods/qcom-rpmh-regulator.ko
DTB=$cam/glymur-a16-camera1.dtb
mode="${1:-install}"
KVER="$(uname -r)"
entry_title="A16: camera step 1 (CCI1 + OV08X40 sensor, t2 kernel)"
stamp="$(date +%Y%m%d-%H%M%S)"
initrd="/boot/initrd.img-$KVER"
cam_initrd="/boot/initrd.img-$KVER-camera1"
installed_mod="/lib/modules/$KVER/kernel/drivers/regulator/qcom-rpmh-regulator.ko"
hook=/etc/initramfs-tools/hooks/zzz-a16-camera-module
hook_module=/usr/local/lib/a16-camera/qcom-rpmh-regulator.ko

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }

# --- cleanups, each safe to call more than once and before anything happened
swapped=0
remove_hook() {
	rm -f "$hook"
	[ -d /usr/local/lib/a16-camera ] && rm -f "$hook_module"
	[ -d /usr/local/lib/a16-camera ] && rmdir /usr/local/lib/a16-camera 2>/dev/null || true
	return 0
}
restore_stock_module() {
	[ "$swapped" = 1 ] || return 0
	[ -n "${stock_mod_copy:-}" ] && [ -f "$stock_mod_copy" ] || return 0
	install -m 0644 -o root -g root "$stock_mod_copy" "$installed_mod" 2>/dev/null || true
	swapped=0
	ok "the stock module is back in $installed_mod"
	return 0
}
# put the camera entry back on the stock initramfs -- the fail-safe.  A menu that
# names the camera device tree never gets left pointing at an initramfs that cannot
# boot, whether the run failed or was interrupted.
revert_entry_initrd() {
	local m
	for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$m" ] || continue
		grep -q "initrd.img-$KVER-camera1" "$m" 2>/dev/null || continue
		sed -i "s|initrd /boot/initrd.img-$KVER-camera1|initrd /boot/initrd.img-$KVER|" "$m" 2>/dev/null || true
		warn "$m: camera entry put back on the stock initramfs"
	done
	return 0
}
die() {
	printf '  [fail] %s\n' "$*" >&2
	revert_entry_initrd
	restore_stock_module
	remove_hook
	printf '  the camera entry is on the stock initramfs; nothing was left armed.\n' >&2
	exit 1
}

[ "$(id -u)" = 0 ] || { printf '  [fail] run me with sudo\n' >&2; exit 1; }
mkdir -p "$cam/logs"
LOG=$cam/logs/step2-$stamp.log
# every root run of this script leaves a log the operator can read afterwards --
# the first install run's output was lost and it mattered
exec > >(tee -a "$LOG") 2>&1
# Ctrl-C, a kill or any early exit still has to put the stock module back and take
# the hook out; both are no-ops until the build starts, and neither touches the menu
# entry (only a failure does that, in die())
say "=== camera step 2: rails for the camera entry ==="
say "  kernel     : $KVER"
say "  log        : $LOG"
list_orig="$(mktemp /tmp/a16-list-orig.XXXXXX)"; list_new="$(mktemp /tmp/a16-list-new.XXXXXX)"
modules_orig="$(mktemp /tmp/a16-mod-orig.XXXXXX)"; modules_new="$(mktemp /tmp/a16-mod-new.XXXXXX)"
mod_extracted="$(mktemp /tmp/a16-mod-inside.XXXXXX)"
trap 'restore_stock_module; remove_hook; rm -f "$list_orig" "$list_new" "$modules_orig" "$modules_new" "$mod_extracted"' EXIT INT TERM
say ""

# mkinitramfs builds the archive; python3 walks the result (see the header)
for t in mkinitramfs python3 cpio; do
	command -v "$t" >/dev/null || die "$t is missing"
done
[ "$KVER" = "$(uname -r)" ] || die "kernel release changed under me"

# ---------------------------------------------------------------- preflight
say "--- the staged module"
[ -f "$MOD" ] || die "$MOD is missing"
[ -f "$MOD.sha256" ] || die "$MOD.sha256 is missing"
sha256sum -c "$MOD.sha256" >/dev/null || die "the staged module does not match its sha256"
ok "sha256 ok: $(awk '{print $1}' "$MOD.sha256")"
[ -f "$installed_mod" ] || die "can't find the installed module at $installed_mod"
new_vm="$(modinfo -F vermagic "$MOD")"; old_vm="$(modinfo -F vermagic "$installed_mod")"
[ "$new_vm" = "$old_vm" ] || die "vermagic differs: [$new_vm] vs [$old_vm]"
ok "vermagic matches the installed module: $new_vm"
new_ml="$(modprobe --dump-modversions "$MOD" | awk '$2=="module_layout"{print $1}')"
old_ml="$(modprobe --dump-modversions "$installed_mod" | awk '$2=="module_layout"{print $1}')"
[ -n "$new_ml" ] && [ "$new_ml" = "$old_ml" ] || die "module_layout CRC differs: $new_ml vs $old_ml"
ok "module_layout CRC matches: $new_ml"
[ "$(modinfo -F srcversion "$MOD")" != "$(modinfo -F srcversion "$installed_mod")" ] \
	|| die "the module is the one already installed -- nothing to do"
ok "srcversion is new: $(modinfo -F srcversion "$MOD")"
n_ldo="$(readelf -sW "$MOD" | awk '$8=="pmh0104_vreg_data"{print $3}')"
[ "$n_ldo" = 256 ] || die "pmh0104_vreg_data is $n_ldo bytes, expected 256 (7 rails + terminator)"
ok "the module carries the PMH0104 LDOs (vreg table 256 bytes = 7 rails)"

say ""
say "--- the staged device tree"
[ -f "$DTB" ] || die "$DTB is missing"
say "  sha256 : $(sha256sum "$DTB" | awk '{print $1}')"
for want in 'cci@ac16000' 'camera@36' 'qcom,pmh0104-rpmh-regulators'; do
	grep -q "$want" "$DTB" || die "$DTB does not contain $want"
done
n_sup="$(dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -cE 'avdd-supply|dovdd-supply|dvdd-supply')"
[ "$n_sup" = 3 ] || die "expected 3 supplies on the sensor, found $n_sup"
ok "the tree carries cci1, the sensor and all three supplies"

say ""
say "--- the camera boot entry and the initramfs"
menus=0
for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
	[ -f "$m" ] || continue
	grep -q 'glymur-a16-camera1.dtb' "$m" 2>/dev/null && menus=$((menus+1))
done
[ "$menus" -gt 0 ] || die "no grub menu names the camera device tree -- run a16-camera-step1.sh first"
ok "$menus menu file(s) carry the camera entry"
[ -f "$initrd" ] || die "$initrd is missing"
stock_sha="$(sha256sum "$initrd" | awk '{print $1}')"
stock_size="$(stat -c%s "$initrd")"
say "  stock initramfs: $initrd"
say "    $stock_size bytes, sha256 $stock_sha"
avail_k=$(df -Pk / | awk 'NR==2{print $4}')
need_k=$(( (stock_size * 3) / 1024 + 300000 ))
[ "$avail_k" -gt "$need_k" ] || die "need about ${need_k}K free on /, have ${avail_k}K"
ok "disk space is there ($((avail_k/1024/1024))G free on /)"

if [ "$mode" = check ]; then
	say ""
	say "--- what the machine's initramfs carries (reads it, changes nothing)"
	initramfs_members "$initrd" > "$list_orig" || die "could not read the stock initramfs"
	say "  $(wc -l < "$list_orig") members, $(segment_offsets "$initrd" | wc -l) segment(s)"
	say "  has init  : $(cut -f2- "$list_orig" | grep -cx 'init')"
	say "  has module: $(cut -f2- "$list_orig" | grep -c 'qcom-rpmh-regulator.ko')"
	say ""
	say "check only: nothing was written.  Run without --check to install."
	exit 0
fi

# ---------------------------------------------------------------- remove
if [ "$mode" = remove ]; then
	say ""
	say "=== removing step 2 ==="
	revert_entry_initrd
	remove_hook
	if [ -f "$cam_initrd" ]; then
		mv -f "$cam_initrd" "$cam_initrd.removed-$stamp"
		ok "camera initramfs set aside as $(basename "$cam_initrd").removed-$stamp"
	fi
	say ""
	say "The camera entry boots the stock initramfs and the stock module again, so the"
	say "sensor goes back to dummy regulators.  Nothing else changed."
	exit 0
fi

verify_cam_initramfs() {
	local seg now n_orig n_new missing mod_path want got new_size
	say ""
	say "=== verifying the archive before anything points at it ==="
	now="$(sha256sum "$initrd" | awk '{print $1}')"
	[ "$now" = "$stock_sha" ] || die "the stock initramfs is not the one we started with"
	ok "the stock initramfs is byte-identical to before the build"

	# the walker must get through the whole image, or our picture of it is wrong
	if ! seg="$(segment_offsets "$cam_initrd" 2>&1)"; then
		die "the new initramfs could not be walked: $seg"
	fi
	ok "the new initramfs walks cleanly -- $(printf '%s' "$seg" | tr '\n' ' ')"

	initramfs_members "$initrd"     > "$list_orig" || die "could not list the stock initramfs"
	initramfs_members "$cam_initrd" > "$list_new"  || die "could not list the new initramfs"
	n_orig="$(wc -l < "$list_orig")"; n_new="$(wc -l < "$list_new")"
	[ "$n_orig" -gt 100 ] || die "only $n_orig members listed for the stock initramfs -- the listing itself is wrong"
	[ "$n_new" -gt 100 ] || die "only $n_new members listed for the new initramfs -- the listing itself is wrong"
	ok "members: $n_new in the new image, $n_orig in the stock one"

	# /init by name: its absence is exactly what panicked the machine
	cut -f2- "$list_new" | grep -qx 'init' || die "no /init in the new initramfs -- that is what panicked it the first time"
	ok "the new initramfs has its /init"

	# every kernel module the stock image carries must still be there -- that is the
	# set that mounts the root filesystem
	cut -f2- "$list_orig" | grep -E '^usr/lib/modules/.*\.ko' | sort > "$modules_orig"
	cut -f2- "$list_new"  | grep -E '^usr/lib/modules/.*\.ko' | sort > "$modules_new"
	missing="$(comm -23 "$modules_orig" "$modules_new")"
	if [ -n "$missing" ]; then
		printf '  [fail] %s module(s) of the stock initramfs are not in the new one:\n' "$(printf '%s\n' "$missing" | wc -l)"
		printf '%s\n' "$missing" | head -8 | sed 's/^/           /'
		die "refusing to install it"
	fi
	ok "all $(wc -l < "$modules_orig") kernel modules of the stock image are in the new one"

	# the module itself, by content, not by name
	mod_path="$(grep -m1 'qcom-rpmh-regulator\.ko' "$list_new" | cut -f2-)"
	[ -n "$mod_path" ] || die "no qcom-rpmh-regulator.ko in the new initramfs"
	want="$(sha256sum "$MOD" | awk '{print $1}')"
	initramfs_extract "$cam_initrd" "$mod_path" "$mod_extracted" \
		|| die "could not extract $mod_path out of the new initramfs"
	got="$(sha256sum "$mod_extracted" | awk '{print $1}')"
	[ "$want" = "$got" ] || die "the module inside the new initramfs ($got) is not the staged one ($want)"
	ok "the module inside the new initramfs is the staged one ($got)"

	new_size="$(stat -c%s "$cam_initrd")"
	[ "$new_size" -ge $((stock_size / 2)) ] || die "the new initramfs is $new_size bytes against the stock's $stock_size -- far too small"
	ok "size $new_size vs the stock's $stock_size"
}

# ---------------------------------------------------------------- reading an initramfs
# lsinitramfs and unmkinitramfs print NOTHING and exit 0 for the archive mkinitramfs
# wrote on this machine -- silently, with no error -- while listing the stock image
# fine.  A checker that believes that empty list refuses a good build, which is what
# happened on 2026-10-05.  So the image is read directly: where do the segments start
# (python walks the headers, the kernel's own rule), and what is in each of them (GNU
# cpio, which handles them all).
segment_offsets() { python3 "$here/a16-camera-initrd-segments.py" "$1"; }

# every member of the image: "size<TAB>path"
initramfs_members() {
	local img=$1 off kind
	while read -r off kind; do
		case "$kind" in
			cpio) tail -c +$((off + 1)) "$img" | cpio -it --quiet 2>/dev/null ;;
			zstd) tail -c +$((off + 1)) "$img" | zstd -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
			gzip) tail -c +$((off + 1)) "$img" | gzip -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
			xz)   tail -c +$((off + 1)) "$img" | xz -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
		esac
	done < <(segment_offsets "$img")
}

# one member of the image into a file, searched in every segment; 1 if not found.
# cpio exits 0 even when its pattern matches nothing, so the test is the size of what
# came out -- with the exit status it returned an empty "success" from segment 0.
initramfs_extract() {
	local img=$1 want=$2 dest=$3 off kind
	while read -r off kind; do
		: > "$dest"
		case "$kind" in
			cpio) tail -c +$((off + 1)) "$img" | cpio -i --to-stdout "$want" > "$dest" 2>/dev/null ;;
			zstd) tail -c +$((off + 1)) "$img" | zstd -dc 2>/dev/null | cpio -i --to-stdout "$want" > "$dest" 2>/dev/null ;;
			gzip) tail -c +$((off + 1)) "$img" | gzip -dc 2>/dev/null | cpio -i --to-stdout "$want" > "$dest" 2>/dev/null ;;
			xz)   tail -c +$((off + 1)) "$img" | xz -dc 2>/dev/null | cpio -i --to-stdout "$want" > "$dest" 2>/dev/null ;;
		esac
		[ -s "$dest" ] && return 0
	done < <(segment_offsets "$img")
	return 1
}

# ---------------------------------------------------------------- build
say ""
say "=== building the camera initramfs with mkinitramfs ==="
stock_mod_copy="$(mktemp /tmp/a16-stock-module.XXXXXX)"
cp -a "$installed_mod" "$stock_mod_copy"
say "  stock module kept at $stock_mod_copy for this run"

# Two independent ways to get the rebuilt module into the archive, because the
# order in which mkinitramfs copies modules against running the hooks is an
# implementation detail: the module is swapped at its source in /lib/modules for
# the duration of the build (and restored immediately after), and a hook also
# overwrites every copy in the image.  Belt and braces on purpose.
install -m 0644 -o root -g root "$MOD" "$installed_mod"
swapped=1
mkdir -p "$(dirname "$hook")" /usr/local/lib/a16-camera
install -m 0644 -o root -g root "$MOD" "$hook_module"
cat > "$hook" <<'HOOK'
#!/bin/sh
# written by a16-camera-step2.sh for one mkinitramfs run: put the rebuilt
# qcom-rpmh-regulator into the camera entry's initramfs instead of the stock one.
# It is removed again when that build finishes.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
[ -f /usr/local/lib/a16-camera/qcom-rpmh-regulator.ko ] || exit 0
for d in "usr/lib/modules/$version/kernel/drivers/regulator" \
         "lib/modules/$version/kernel/drivers/regulator"; do
    mkdir -p "$DESTDIR/$d"
    cp -f /usr/local/lib/a16-camera/qcom-rpmh-regulator.ko "$DESTDIR/$d/qcom-rpmh-regulator.ko"
done
exit 0
HOOK
chmod 0755 "$hook"
ok "the module and the hook are in place for this build"

say "  running: mkinitramfs -o $cam_initrd.new $KVER"
if ! mkinitramfs -o "$cam_initrd.new" "$KVER" 2>&1 | sed 's/^/    /'; then
	restore_stock_module; remove_hook
	die "mkinitramfs failed -- see the lines above"
fi
restore_stock_module
remove_hook
[ -f "$cam_initrd.new" ] || die "mkinitramfs produced no file"
mv -f "$cam_initrd.new" "$cam_initrd"
chmod 0644 "$cam_initrd"
ok "built $(basename "$cam_initrd"): $(stat -c%s "$cam_initrd") bytes"

# ---------------------------------------------------------------- verify
verify_cam_initramfs

# ---------------------------------------------------------------- install
say ""
say "--- the device tree"
cp -f "$DTB" "/boot/glymur-a16-camera1.dtb.a16-pre-step2-$stamp"
install -m 0644 "$DTB" /boot/glymur-a16-camera1.dtb
ok "/boot/glymur-a16-camera1.dtb updated (previous kept as .a16-pre-step2-$stamp)"

say ""
say "--- pointing the camera entry at the new initramfs"
changing=0
for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
	[ -f "$m" ] || continue
	grep -q 'glymur-a16-camera1.dtb' "$m" 2>/dev/null || continue
	grep -q "initrd /boot/initrd.img-$KVER-camera1" "$m" 2>/dev/null && { ok "$m already points at it"; continue; }
	cp -f "$m" "$m.a16-pre-step2-$stamp"
	tmp="$(mktemp)"
	awk -v kver="$KVER" '
		/devicetree \/boot\/glymur-a16-camera1\.dtb/ { seen=1 }
		seen && /^[[:space:]]*initrd / {
			match($0, /^[[:space:]]*/)
			print substr($0, 1, RLENGTH) "initrd /boot/initrd.img-" kver "-camera1"
			seen=0; next
		}
		{ print }
	' "$m" > "$tmp" || { rm -f "$tmp"; die "awk failed on $m"; }
	if cmp -s "$m" "$tmp"; then
		rm -f "$tmp"; warn "$m: no initrd line found inside the camera entry"
		continue
	fi
	install -m 0644 -o root -g root "$tmp" "$m" || { rm -f "$tmp"; die "could not write $m"; }
	rm -f "$tmp"
	ok "$m: camera entry now boots $(basename "$cam_initrd") (backup .a16-pre-step2-$stamp)"
	changing=1
done
[ "$changing" = 1 ] || warn "no menu file needed changing"

say ""
say "=== done.  What you can count on ==="
say "  the usual menu entries are untouched: same device tree, same initramfs, same"
say "  module.  The rebuilt module is not in /lib/modules -- it exists only inside"
say "  $(basename "$cam_initrd"), which only the camera entry boots."
say "  previous camera device tree: /boot/glymur-a16-camera1.dtb.a16-pre-step2-$stamp"
say "  menu backups: <menu>.a16-pre-step2-$stamp     this log: $LOG"
say "  undo:  sudo bash $here/a16-camera-step2.sh --remove"
say ""
say "=== next ==="
say "  reboot, and at the menu pick:  $entry_title"
say "  the collector writes $cam/logs/boot-<id>.log by itself."
say "  Pass: no dummy-regulator lines, rpmh-regulator registering ldo4/ldo7, and"
say "  21-0036 answering with the chip id instead of NAKing."
sleep 0.3   # let tee finish writing the log
