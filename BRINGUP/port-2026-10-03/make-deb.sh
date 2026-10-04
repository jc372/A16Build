#!/usr/bin/env bash
# make-deb.sh -- package an already-built A16 kernel as a .deb, without debhelper.
#
#   bash make-deb.sh                       # tree and output in the default places
#   bash make-deb.sh --tree DIR --out DIR
#
# Why this exists: `make bindeb-pkg` refuses to run on this Ubuntu development branch because its
# Build-Depends (debhelper-compat) has no candidate in the archive. The packaging step itself
# needs no such tooling, so this stages the layout and calls dpkg-deb directly. Needs no root:
# modules are installed into a staging directory with INSTALL_MOD_PATH.
#
# What the resulting package does NOT have, and why that is acceptable here: no initramfs
# regeneration and no bootloader hook, because those live in the distribution's kernel
# maintainer scripts. The boot entry on this machine is written from Windows anyway (README),
# and a16-port.sh covers the install-side case.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${HOME}/build/next-20261002-repull"
OUT="${HOME}/a16-deb"
STRIP=1
while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift ;;
		--out)  OUT="$2"; shift ;;
		--no-strip) STRIP=0 ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown option: $1"; exit 2 ;;
	esac
	shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ -d "$TREE" ] || die "no tree at $TREE"
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found"
VER="$(make -s -C "$TREE" kernelrelease)"
[ -n "$VER" ] || die "could not read kernelrelease from $TREE"
[ -f "$TREE/arch/arm64/boot/Image" ] || die "no built Image in $TREE -- build first"

say "release : $VER"
say "tree    : $TREE"
say "out     : $OUT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/a16-deb.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"

say ""
say "=== modules -> staging (no root: INSTALL_MOD_PATH) ==="
if [ "$STRIP" = 1 ]; then
	make -s -C "$TREE" INSTALL_MOD_PATH="$STAGE/usr" INSTALL_MOD_STRIP=1 modules_install >/dev/null \
		|| die "modules_install failed"
else
	make -s -C "$TREE" INSTALL_MOD_PATH="$STAGE/usr" modules_install >/dev/null || die "modules_install failed"
fi
n=$(find "$STAGE/usr/lib/modules/$VER" -name '*.ko*' | wc -l)
say "  $n modules staged, $(du -sh "$STAGE/usr/lib/modules/$VER" | cut -f1)"

say ""
say "=== depmod for the target ==="
if command -v depmod >/dev/null 2>&1; then
	if depmod -b "$STAGE/usr" "$VER" 2>/tmp/depmod.err; then   # modules live under usr/
		say "  modules.dep written"
	else
		say "  depmod returned non-zero:"; sed "s/^/    /" /tmp/depmod.err | head -5
	fi
else
	say "  no depmod here; the postinst runs it on the target"
fi

say ""
say "=== kernel, config, dtb ==="
mkdir -p "$STAGE/boot"
install -m 644 "$TREE/arch/arm64/boot/Image" "$STAGE/boot/vmlinuz-$VER"
install -m 644 "$TREE/.config" "$STAGE/boot/config-$VER"
[ -f "$TREE/System.map" ] && install -m 644 "$TREE/System.map" "$STAGE/boot/System.map-$VER" || true
DTB="$TREE/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
[ -f "$DTB" ] && install -m 644 "$DTB" "$STAGE/boot/glymur-a16-$VER.dtb" || say "  note: no A16 dtb in the tree"
say "  boot/: $(ls "$STAGE/boot" | tr '\n' ' ')"

say ""
say "=== control and maintainer scripts ==="
mkdir -p "$STAGE/DEBIAN"
SIZE=$(du -sk "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: linux-image-$VER
Version: $VER
Architecture: arm64
Maintainer: agentbhome <agentbhome@gmail.com>
Section: kernel
Priority: optional
Depends: kmod
Installed-Size: $SIZE
Description: Linux kernel $VER for the ASUS Zenbook A16 (UX3607OA)
 Built from linux-next next-20261002 with the A16 port applied: display, external display,
 Bluetooth, suspend, and the embedded controller.
 .
 No initramfs or bootloader hooks: add the boot entry yourself (see the repository README).
EOF
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if command -v depmod >/dev/null 2>&1; then
    depmod -a $VER || true
fi
echo "linux-image-$VER installed."
echo "Add a boot entry for /boot/vmlinuz-$VER (with /boot/glymur-a16-$VER.dtb and"
echo "/boot/initrd.img-$VER) -- see the A16Build README."
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

say ""
say "=== dpkg-deb ==="
DEB="$OUT/linux-image-${VER}_${VER}_arm64.deb"
COMPRESS=zstd
dpkg-deb --root-owner-group -Z"$COMPRESS" --build "$STAGE" "$DEB" 2>/dev/null || {
	say "  zstd unavailable, using xz"
	dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB" || die "dpkg-deb failed"
}
say ""
say "package : $DEB"
say "size    : $(du -h "$DEB" | cut -f1)"
if dpkg-deb -c "$DEB" 2>/dev/null | grep -q "modules.dep$"; then
	say "depmod  : modules.dep is in the package"
else
	say "depmod  : NO modules.dep -- the postinst must run depmod on install"
fi
say "sha256  : $(sha256sum "$DEB" | cut -d' ' -f1)"
say ""
say "contents:"
dpkg-deb -c "$DEB" 2>/dev/null | head -5 | awk '{print "  "$0}'
say "  ... plus $(dpkg-deb -c "$DEB" 2>/dev/null | wc -l) entries total"
