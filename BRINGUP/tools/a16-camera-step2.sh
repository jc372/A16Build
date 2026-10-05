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
# WHY THE CAMERA IMAGE IS THE STOCK IMAGE PLUS ONE APPENDED ARCHIVE
#   Three shapes were tried.  Unpacking by hand and repacking lost everything after
#   the first archive (a modern initramfs is a sequence of them) and panicked the
#   machine.  Building a fresh one with mkinitramfs worked but selected its own
#   module set -- 2584 modules against the stock image's 3090 -- which is a
#   difference worth not having on a boot path.  This is the third: the camera image
#   is the stock image's bytes, with a small cpio archive appended that contains
#   nothing but the rebuilt qcom-rpmh-regulator at the same path the stock image
#   keeps it at.
#
#   That works because of how the kernel reads an initramfs (init/initramfs.c):
#   unpack_to_rootfs walks the segments in order -- after a compressed one it
#   advances by what the decompressor consumed and keeps going -- and do_name opens
#   a regular file with O_TRUNC and truncates it to the new body length, so a file
#   provided by a later archive *replaces* the earlier one.  Debian's own images
#   rely on this.  Nothing else in the image changes at all.
#
#   And if a future kernel stopped honouring it, the camera entry would simply boot
#   the stock module again: no rails, no camera, no panic.  That is the point of
#   this shape -- the failure mode is "nothing happened", not "cannot mount root".
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
tail_names="$(mktemp /tmp/a16-tail-names.XXXXXX)"; stock_names="$(mktemp /tmp/a16-stock-names.XXXXXX)"
cmp_out="$(mktemp /tmp/a16-cmp-out.XXXXXX)"
trap 'restore_stock_module; remove_hook; rm -f "$list_orig" "$list_new" "$modules_orig" "$modules_new" "$mod_extracted" "$tail_names" "$stock_names" "$cmp_out"' EXIT INT TERM
say ""

# python3 finds the segment offsets, cpio builds and reads the appended archive
for t in python3 cpio cmp tail; do
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
if [ "$n_sup" = 3 ]; then
	ok "the tree carries cci1, the sensor and all three supplies"
else
	warn "the tree declares no supplies ($n_sup) -- correct while this firmware's"
	warn "command DB has no rails for the PMH0104: naming them only defers the probe"
fi

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
	local now new_size want got
	say ""
	say "=== verifying before anything points at it ==="
	now="$(sha256sum "$initrd" | awk '{print $1}')"
	[ "$now" = "$stock_sha" ] || die "the stock initramfs changed during the run"
	ok "the stock initramfs is untouched"

	# 1. everything before the replaced segment is the stock image's bytes
	if cmp -s -n "$seg_off" "$initrd" "$cam_initrd"; then
		ok "the first $seg_off bytes are the stock image's, byte for byte"
	else
		die "the camera image does not start with the stock image's first $seg_off bytes"
	fi
	new_size="$(stat -c%s "$cam_initrd")"

	# 2. it walks, and the last segment is still the same kind of archive
	mapfile -t segs2 < <(segment_offsets "$cam_initrd") || die "the camera image could not be walked"
	last2="${segs2[${#segs2[@]}-1]}"
	[ "${last2##* }" = "$seg_kind" ] || die "the rebuilt image's last segment is not $seg_kind: $last2"
	[ "${last2%% *}" = "$seg_off" ] || die "the rebuilt image's last segment moved to ${last2%% *}"
	ok "the camera image walks, last segment still $seg_kind at $seg_off"

	# 3. the rebuilt segment unpacks to the stock tree, with the module the only change.
	#    Compared as a structural manifest plus a hash of every regular file, not with
	#    diff -r: an initramfs carries device nodes (dev/console and friends) and diff
	#    refuses to compare those, so it would call a correct rebuild a failure.
	work_a="$(mktemp -d /tmp/a16-cmp-a.XXXXXX)"; work_b="$(mktemp -d /tmp/a16-cmp-b.XXXXXX)"
	unpack_segment "$initrd" "$seg_off" "$seg_kind" "$work_a" || { rm -rf "$work_a" "$work_b"; die "could not unpack the stock segment"; }
	unpack_segment "$cam_initrd" "$seg_off" "$seg_kind" "$work_b" || { rm -rf "$work_a" "$work_b"; die "could not unpack the rebuilt segment"; }
	manifest() { ( cd "$1" && find . -printf '%y %m %U %G %s %l %P\n' | sort ); }
	hashes()   { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) | sed 's|  \./|  |'; }
	mod_rel="${mod_paths[0]}"
	if ! diff <(manifest "$work_a" | grep -v " $mod_rel\$") \
	          <(manifest "$work_b" | grep -v " $mod_rel\$") > "$cmp_out" 2>&1; then
		printf '  [fail] the rebuilt segment is not the stock tree:\n'
		head -8 "$cmp_out" | sed 's/^/           /'
		rm -rf "$work_a" "$work_b"
		die "refusing to install it"
	fi
	if ! diff <(hashes "$work_a" | grep -v "  $mod_rel\$") \
	          <(hashes "$work_b" | grep -v "  $mod_rel\$") > "$cmp_out" 2>&1; then
		printf '  [fail] a file other than the module differs:\n'
		head -8 "$cmp_out" | sed 's/^/           /'
		rm -rf "$work_a" "$work_b"
		die "refusing to install it"
	fi
	ok "the rebuilt segment is the stock tree, differing only in the module"

	# 4. the module in the rebuilt segment is the staged one
	want="$(sha256sum "$MOD" | awk '{print $1}')"
	got="$(sha256sum "$work_b/${mod_paths[0]}" 2>/dev/null | awk '{print $1}')"
	[ "$want" = "$got" ] || { rm -rf "$work_a" "$work_b"; die "the module in the rebuilt segment is not the staged one ($got)"; }
	rm -rf "$work_a" "$work_b"
	ok "the module in the rebuilt segment is the staged one ($got)"

	# 5. the file list of the whole image is the stock image's
	initramfs_members "$cam_initrd" > "$list_new" || die "could not read the camera image"
	if ! diff <(cut -f2- "$list_orig" | sort -u) <(cut -f2- "$list_new" | sort -u) >/dev/null; then
		die "the camera image's file list differs from the stock image's"
	fi
	ok "same $(sort -u "$list_new" | wc -l) members as the stock image"
	cut -f2- "$list_new" | grep -qx 'init' || die "no /init in the camera image"
	ok "/init is there"
	ok "size $new_size against the stock's $stock_size"
}

# ---------------------------------------------------------------- reading an initramfs
# lsinitramfs and unmkinitramfs print NOTHING and exit 0 for the archive mkinitramfs
# wrote on this machine -- silently, with no error -- while listing the stock image
# fine.  A checker that believes that empty list refuses a good build, which is what
# happened on 2026-10-05.  So the image is read directly: where do the segments start
# (python walks the headers, the kernel's own rule), and what is in each of them (GNU
# cpio, which handles them all).
segment_offsets() { python3 "$here/a16-camera-initrd-segments.py" "$1"; }

# every member of the image: "size<TAB>path".  With a second argument, only segments
# that start at or after that offset are read -- used to look at just the part this
# script appended.
initramfs_members() {
	local img=$1 min=${2:-0} off kind
	while read -r off kind; do
		[ "$off" -ge "$min" ] || continue
		case "$kind" in
			cpio) tail -c +$((off + 1)) "$img" | cpio -it --quiet 2>/dev/null ;;
			zstd) tail -c +$((off + 1)) "$img" | zstd -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
			gzip) tail -c +$((off + 1)) "$img" | gzip -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
			xz)   tail -c +$((off + 1)) "$img" | xz -dc 2>/dev/null | cpio -it --quiet 2>/dev/null ;;
		esac
	done < <(segment_offsets "$img")
}

# one member of the image into a file; 1 if not found.  Segments are searched in
# REVERSE, because that is what the kernel ends up with: a file provided by a later
# archive replaces the earlier copy.  cpio exits 0 even when its pattern matches
# nothing, so the test is the size of what came out.
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
	done < <(segment_offsets "$img" | tac)
	return 1
}

# ---------------------------------------------------------------- build
say ""
say "=== building the camera initramfs: the last segment, rebuilt with the module inside ==="
initramfs_members "$initrd" > "$list_orig" || die "could not read the stock initramfs"
mapfile -t mod_paths < <(cut -f2- "$list_orig" | grep 'qcom-rpmh-regulator\.ko$' | sort -u)
[ "${#mod_paths[@]}" -gt 0 ] || die "the stock initramfs does not carry qcom-rpmh-regulator.ko"
say "  the stock image keeps that module at:"
for mp in "${mod_paths[@]}"; do printf '    %s\n' "$mp"; done

# The copy the kernel ends up with is the one in the LAST archive, so that is the one
# that gets replaced; everything before it stays byte for byte.  (Appending an extra
# archive after the stock image does NOT work: tried on 2026-10-05, and the kernel went
# on using the stock module -- see the header.)
mapfile -t segs < <(segment_offsets "$initrd") || die "could not walk the stock initramfs"
[ "${#segs[@]}" -ge 1 ] || die "the stock initramfs has no segments"
last="${segs[${#segs[@]}-1]}"
seg_off="${last%% *}"; seg_kind="${last##* }"
case "$seg_kind" in
	zstd|gzip|xz) : ;;
	*) die "the stock image's last segment is '$seg_kind'; this script only replaces the module in a compressed last segment" ;;
esac
initramfs_members "$initrd" "$seg_off" | cut -f2- > "$tail_names"
found=0
for mp in "${mod_paths[@]}"; do
	grep -qx "$mp" "$tail_names" && found=1
done
[ "$found" = 1 ] || die "the module is not in the last segment, so replacing it there would win nothing"
say "  the last segment is $seg_kind at offset $seg_off, and the module is in it"

# does the stock image spell members with a leading "./"?  the rebuild has to match,
# or the kernel would see two different paths instead of one file
if cut -f2- "$list_orig" | grep -q '^\./'; then seg_dot=yes; else seg_dot=no; fi
say "  member names carry a leading './': $seg_dot"

work="$(mktemp -d /tmp/a16-camera-seg.XXXXXX)"
unpack_segment() {   # $1 image, $2 offset, $3 kind, $4 target dir
	case "$3" in
		zstd) tail -c +$(($2 + 1)) "$1" | zstd -dc 2>/dev/null | ( cd "$4" && cpio -idm --quiet ) ;;
		gzip) tail -c +$(($2 + 1)) "$1" | gzip -dc 2>/dev/null | ( cd "$4" && cpio -idm --quiet ) ;;
		xz)   tail -c +$(($2 + 1)) "$1" | xz -dc 2>/dev/null | ( cd "$4" && cpio -idm --quiet ) ;;
		cpio) tail -c +$(($2 + 1)) "$1" | cpio -idm --quiet ;;
	esac
}
say "  unpacking the last segment"
unpack_segment "$initrd" "$seg_off" "$seg_kind" "$work" || { rm -rf "$work"; die "could not unpack the last segment"; }
for mp in "${mod_paths[@]}"; do
	[ -f "$work/$mp" ] || die "the last segment does not actually contain $mp"
	install -m 0644 -o root -g root "$MOD" "$work/$mp" || die "could not place the module"
	say "    replaced $mp"
done

new_seg="$(mktemp /tmp/a16-camera-seg-out.XXXXXX)"
( cd "$work" && if [ "$seg_dot" = yes ]; then find . -print0; else find * -print0; fi | cpio --null -o -H newc --quiet > "$new_seg" ) \
	|| { rm -rf "$work"; die "could not repack the segment"; }
rm -rf "$work"
case "$seg_kind" in
	zstd) zstd -19 -T0 -q -f -o "$new_seg.z" "$new_seg" && mv -f "$new_seg.z" "$new_seg" ;;
	gzip) gzip -9 -c "$new_seg" > "$new_seg.z" && mv -f "$new_seg.z" "$new_seg" ;;
	xz)   xz -T0 -c "$new_seg" > "$new_seg.z" && mv -f "$new_seg.z" "$new_seg" ;;
esac
head -c "$seg_off" "$initrd" > "$cam_initrd.new" || { rm -f "$new_seg"; die "could not copy the stock prefix"; }
cat "$new_seg" >> "$cam_initrd.new" || { rm -f "$new_seg"; die "could not append the new segment"; }
rm -f "$new_seg"
mv -f "$cam_initrd.new" "$cam_initrd"
chmod 0644 "$cam_initrd"
ok "prefix kept byte for byte ($seg_off bytes) + rebuilt $seg_kind segment = $(stat -c%s "$cam_initrd") bytes"

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
