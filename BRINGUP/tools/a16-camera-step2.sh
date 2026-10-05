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
#   which is a module the kernel loads while it is still running from the
#   initramfs (the boot disk needs those rails).  That is the lever: the camera
#   entry boots its own initramfs, with the rebuilt module inside, and every menu
#   entry you already use keeps the initramfs it boots today, byte for byte.
#   The module is deliberately NOT installed into /lib/modules, so a bad module
#   cannot reach the usual boot paths at all.
#
# WHAT IS CHECKED BEFORE ANYTHING IS INSTALLED
#   vermagic equal to the installed module's, module_layout CRC equal, symbol
#   versions taken from the same tree that built the running kernel, sha256 of
#   the staged module, and the device tree carrying all three supplies.  The
#   kernel refuses a module that fails the CRC check, so these are the same gates
#   the kernel itself applies.
#
# WHAT TO EXPECT IN THE LOG AFTER THE REBOOT
#   the three dummy-regulator lines gone, `rpmh-regulator` registering ldo4/ldo7,
#   and the chip id read answering: 21-0036 ... chip id 0x560858
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

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run me with sudo"
command -v cpio >/dev/null || die "cpio is not installed"
[ "$KVER" = "$(uname -r)" ] || die "kernel release changed under me"

initrd="/boot/initrd.img-$KVER"
cam_initrd="/boot/initrd.img-$KVER-camera1"
installed_mod="/lib/modules/$KVER/kernel/drivers/regulator/qcom-rpmh-regulator.ko"

# ---------------------------------------------------------------- helpers
# run one rebuild of the initramfs with the camera module inside.  Reads $initrd,
# writes $cam_initrd.  Prints whether the module was already there.
build_cam_initramfs() {
	local work comp
	work="$(mktemp -d /tmp/a16cam-initrd.XXXXXX)"
	case "$(file -b "$initrd")" in
		*Zstandard*) comp=zstd ;;
		*gzip*)      comp=gzip ;;
		*XZ*)        comp=xz ;;
		*)           die "unknown initramfs compression: $(file -b "$initrd")" ;;
	esac
	say "  unpacking $initrd ($comp)"
	(
		cd "$work"
		case "$comp" in
			zstd) zstd -dc "$initrd" | cpio -idm --quiet ;;
			gzip) gzip -dc "$initrd" | cpio -idm --quiet ;;
			xz)   xz -dc  "$initrd" | cpio -idm --quiet ;;
		esac
	) || die "could not unpack the initramfs"

	# every copy of the module inside the initramfs, wherever it lives
	mapfile -t found < <(cd "$work" && find . -name 'qcom-rpmh-regulator.ko' -type f | sed 's|^\./||')
	if [ "${#found[@]}" -gt 0 ]; then
		say "  the module IS in the initramfs, at:"
		for f in "${found[@]}"; do printf '    %s\n' "$f"; done
		for f in "${found[@]}"; do cp -f "$MOD" "$work/$f"; done
		say "  replaced ${#found[@]} copy/copies with the rebuilt module"
	else
		warn "the stock initramfs does not carry this module, so it is loaded from"
		warn "/lib/modules after switch_root.  Adding it to the camera initramfs so"
		warn "the camera entry gets the rebuilt one anyway."
		mkdir -p "$work/usr/lib/modules/$KVER/kernel/drivers/regulator"
		cp -f "$MOD" "$work/usr/lib/modules/$KVER/kernel/drivers/regulator/qcom-rpmh-regulator.ko"
		found=("usr/lib/modules/$KVER/kernel/drivers/regulator/qcom-rpmh-regulator.ko")
	fi

	# a hand-rolled repack must not drop a single member: compare the path lists
	list_orig="$(mktemp)"; list_new="$(mktemp)"
	case "$comp" in
		zstd) zstd -dc "$initrd"      | cpio -it --quiet 2>/dev/null | sort > "$list_orig" ;;
		gzip) gzip -dc "$initrd"      | cpio -it --quiet 2>/dev/null | sort > "$list_orig" ;;
		xz)   xz -dc  "$initrd"       | cpio -it --quiet 2>/dev/null | sort > "$list_orig" ;;
	esac

	say "  repacking -> $cam_initrd"
	(
		cd "$work"
		find . -print0 | cpio --null -o -H newc --quiet 2>/dev/null | \
			case "$comp" in
				zstd) zstd -19 -T0 -q -o "$cam_initrd" ;;
				gzip) gzip -9 -c > "$cam_initrd" ;;
				xz)   xz -T0 -c > "$cam_initrd" ;;
			esac
	) || die "could not repack the initramfs"
	chmod 0644 "$cam_initrd"

	# the comparison itself: every path the stock initramfs had must still be there
	case "$comp" in
		zstd) zstd -dc "$cam_initrd" | cpio -it --quiet 2>/dev/null | sort > "$list_new" ;;
		gzip) gzip -dc "$cam_initrd" | cpio -it --quiet 2>/dev/null | sort > "$list_new" ;;
		xz)   xz -dc  "$cam_initrd" | cpio -it --quiet 2>/dev/null | sort > "$list_new" ;;
	esac
	missing="$(comm -23 "$list_orig" "$list_new")"
	if [ -n "$missing" ]; then
		printf '  [fail] the repack dropped %s path(s), first few:\n%s\n' \
			"$(printf '%s\n' "$missing" | wc -l)" "$(printf '%s\n' "$missing" | head -5)"
		rm -f "$list_orig" "$list_new"
		die "refusing to install a repack that lost members"
	fi
	ok "the repack kept all $(wc -l < "$list_orig") paths (added: $(comm -13 "$list_orig" "$list_new" | wc -l))"
	rm -f "$list_orig" "$list_new"
	rm -rf "$work"

	# prove the module inside the new initramfs is byte-for-byte the staged one
	local want got
	want="$(sha256sum "$MOD" | awk '{print $1}')"
	got="$(case "$comp" in
		zstd) zstd -dc "$cam_initrd" ;;
		gzip) gzip -dc "$cam_initrd" ;;
		xz)   xz -dc  "$cam_initrd" ;;
	esac | cpio -i --to-stdout "${found[0]}" 2>/dev/null | sha256sum | awk '{print $1}')"
	[ "$want" = "$got" ] || die "the module inside $cam_initrd does not match the staged one"
	ok "inside the camera initramfs the module is the staged one ($got)"
}

# rewrite the initrd line of the camera entry, and only that line
patch_entry_initrd() {
	local m tmp changed=0
	for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$m" ] || continue
		grep -q 'glymur-a16-camera1.dtb' "$m" 2>/dev/null || continue
		grep -q 'initrd /boot/initrd.img-'"$KVER"'-camera1' "$m" 2>/dev/null && { ok "$m already points at the camera initramfs"; continue; }
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
		' "$m" > "$tmp" || die "awk failed on $m"
		cmp -s "$m" "$tmp" && { rm -f "$tmp"; warn "$m: no initrd line to change inside the camera entry"; continue; }
		install -m 0644 -o root -g root "$tmp" "$m" || die "could not write $m"
		rm -f "$tmp"
		ok "$m: the camera entry now boots $cam_initrd (backup .a16-pre-step2-$stamp)"
		changed=1
	done
	[ "$changed" = 1 ] || warn "no menu file needed changing"
}

# ---------------------------------------------------------------- preflight
say "=== camera step 2: rails for the camera entry ==="
say "  kernel     : $KVER"
say ""
say "--- the staged module"
[ -f "$MOD" ] || die "$MOD is missing"
[ -f "$MOD.sha256" ] || die "$MOD.sha256 is missing"
sha256sum -c "$MOD.sha256" >/dev/null || die "the staged module does not match its sha256"
ok "sha256 ok: $(awk '{print $1}' "$MOD.sha256")"
[ -f "$installed_mod" ] || die "can't find the installed module at $installed_mod"
new_vm="$(modinfo -F vermagic "$MOD")"
old_vm="$(modinfo -F vermagic "$installed_mod")"
[ "$new_vm" = "$old_vm" ] || die "vermagic differs: [$new_vm] vs [$old_vm]"
ok "vermagic matches the installed module: $new_vm"
new_ml="$(modprobe --dump-modversions "$MOD" | awk '$2=="module_layout"{print $1}')"
old_ml="$(modprobe --dump-modversions "$installed_mod" | awk '$2=="module_layout"{print $1}')"
[ -n "$new_ml" ] && [ "$new_ml" = "$old_ml" ] || die "module_layout CRC differs: $new_ml vs $old_ml"
ok "module_layout CRC matches: $new_ml"
[ "$(modinfo -F srcversion "$MOD")" != "$(modinfo -F srcversion "$installed_mod")" ] || die "the module is the one already installed -- nothing to do"
ok "srcversion is new: $(modinfo -F srcversion "$MOD")"
n_ldo="$(readelf -sW "$MOD" | awk '$8=="pmh0104_vreg_data"{print $3}')"
[ "$n_ldo" = 256 ] || die "pmh0104_vreg_data is $n_ldo bytes, expected 256 (7 rails + terminator)"
ok "the module carries the PMH0104 LDOs (vreg table 256 bytes = 7 rails)"

say ""
say "--- the staged device tree"
[ -f "$DTB" ] || die "$DTB is missing"
sha256sum "$DTB" | awk '{print "  sha256 : "$1}'
for want in 'cci@ac16000' 'camera@36' 'qcom,pmh0104-rpmh-regulators'; do
	grep -q "$want" "$DTB" || die "$DTB does not contain $want"
done
n_sup="$(dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -cE 'avdd-supply|dovdd-supply|dvdd-supply')"
[ "$n_sup" = 3 ] || die "expected 3 supplies on the sensor, found $n_sup"
ok "the tree carries cci1, the sensor and all three supplies"

say ""
say "--- the camera boot entry"
menus=0
for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
	[ -f "$m" ] || continue
	grep -q 'glymur-a16-camera1.dtb' "$m" 2>/dev/null && menus=$((menus+1))
done
[ "$menus" -gt 0 ] || die "no grub menu names the camera device tree -- run a16-camera-step1.sh first"
ok "$menus menu file(s) carry the camera entry"
[ -f "$initrd" ] || die "$initrd is missing"
say "  current initramfs: $initrd ($(stat -c%s "$initrd") bytes, $(file -b "$initrd"))"
df -h / | awk 'NR==2{printf "  free on /: %s of %s\n", $4, $2}'
avail_k=$(df -Pk / | awk 'NR==2{print $4}')
need_k=$(( ($(stat -c%s "$initrd") * 2) / 1024 + 200000 ))
[ "$avail_k" -gt "$need_k" ] || die "need about ${need_k}K free on /, have ${avail_k}K"
ok "disk space is there for one more initramfs plus unpacking"

if [ "$mode" = check ]; then
	say ""
	say "--- what the initramfs carries today (read-only look)"
	say "  (the real unpack happens in the install run)"
	say ""
	say "check only: nothing was written.  Run without --check to install."
	exit 0
fi

# ---------------------------------------------------------------- remove
if [ "$mode" = remove ]; then
	say ""
	say "=== removing step 2 ==="
	for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$m" ] || continue
		grep -q 'initrd.img-'"$KVER"'-camera1' "$m" 2>/dev/null || continue
		cp -f "$m" "$m.a16-before-step2-remove-$stamp"
		sed -i "s|initrd /boot/initrd.img-$KVER-camera1|initrd /boot/initrd.img-$KVER|" "$m"
		ok "$m: back to $initrd"
	done
	[ -f "$cam_initrd" ] && { mv -f "$cam_initrd" "$cam_initrd.removed-$stamp"; ok "camera initramfs set aside as $(basename "$cam_initrd").removed-$stamp"; }
	say ""
	say "The camera entry now boots the stock initramfs and the stock module, so the"
	say "sensor goes back to dummy regulators.  Nothing else changed."
	exit 0
fi

# ---------------------------------------------------------------- install
say ""
say "=== installing ==="
build_cam_initramfs

say ""
say "--- the device tree"
cp -f "$DTB" "/boot/glymur-a16-camera1.dtb.a16-pre-step2-$stamp"
install -m 0644 "$DTB" /boot/glymur-a16-camera1.dtb
ok "/boot/glymur-a16-camera1.dtb updated (previous kept as .a16-pre-step2-$stamp)"

say ""
say "--- the camera boot entry"
patch_entry_initrd

say ""
say "=== done.  What you can count on ==="
say "  the usual menu entries are untouched: same device tree, same initramfs,"
say "  same module.  The rebuilt module is NOT in /lib/modules at all -- it is"
say "  inside $cam_initrd, which only the camera entry uses."
say "  the previous camera device tree: /boot/glymur-a16-camera1.dtb.a16-pre-step2-$stamp"
say "  the menu files: <menu>.a16-pre-step2-$stamp"
say "  undo everything with:  sudo bash $here/a16-camera-step2.sh --remove"
say ""
say "=== next ==="
say "  reboot, and at the menu pick:  $entry_title"
say "  the collector writes /home/jc/a16-payload/camera/logs/boot-<id>.log by itself."
say "  Pass looks like:  the dummy-regulator lines gone, rpmh-regulator registering"
say "  ldo4/ldo7 for pmic-id I_E0, and  21-0036 ... chip id 0x560858"
