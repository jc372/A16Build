#!/usr/bin/env bash
# a16-build-rpmh-regulator-module.sh -- rebuild qcom-rpmh-regulator with 0021 in
# the tree that produced the running kernel, verify it, and stage it for
# a16-camera-step2.sh.  No root needed; nothing is installed here.
#
#   bash a16-build-rpmh-regulator-module.sh
#
# Produces ~/a16-payload/camera/mods/qcom-rpmh-regulator.ko (+ .sha256) and a
# build log beside it.  a16-camera-step2.sh then checks vermagic, module_layout
# CRC and the vreg table size again before it puts the module anywhere near a boot
# path, and installs it into the camera entry's own initramfs only.
#
# Why the tree has to be the running kernel's: with CONFIG_MODVERSIONS the kernel
# checks a CRC for every symbol a module imports.  A tree whose Module.symvers
# came from somewhere else produces a module with empty or foreign CRCs, which the
# kernel refuses to load -- and a module that silently failed to load leaves the
# board without its rails.  That is why the script prints the module_layout CRC
# and compares it with the installed module's rather than trusting a clean build.
set -eu

TREE="${1:-/home/jc/build/next-20261002-repull}"
cam=/home/jc/a16-payload/camera
out=$cam/mods
patch_0021=/home/jc/A16Build/patches/0021-regulator-qcom-rpmh-pmh0104-camera-ldos
V="$(uname -r)"
log=$out/build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$out"

# the same pahole the other module builds use; only needed if the tree wants to
# generate BTF, which this kernel does not carry anyway
export PATH="$HOME/.hermes/cache/scratch/pahole-local/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.hermes/cache/scratch/pahole-local/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"

[ -d "$TREE" ] || { echo "FATAL: no tree at $TREE"; exit 1; }
[ -f "$patch_0021"/*.patch ] 2>/dev/null || true

echo "== tree: $TREE"
echo "== kernel the tree builds: $(make -C "$TREE" --no-print-directory ARCH=arm64 kernelrelease)"
[ "$(make -C "$TREE" --no-print-directory ARCH=arm64 kernelrelease)" = "$V" ] \
	|| { echo "FATAL: that tree does not build the running kernel ($V)"; exit 1; }

echo "== 0021 applied?"
if grep -q 'RPMH_VREG("ldo4",' "$TREE/drivers/regulator/qcom-rpmh-regulator.c"; then
	echo "   yes, the PMH0104 LDOs are in the source"
else
	echo "   no -- applying $patch_0021"
	(cd "$TREE" && patch -p1 < "$patch_0021"/*.patch)
fi

echo "== building drivers/regulator"
# the module build rewrites Module.symvers, so keep the tree's own copy: it is the
# running kernel's symbol versions and nothing else must replace it
cp -a "$TREE/Module.symvers" "$out/Module.symvers.tree-$(date +%Y%m%d-%H%M%S)"
make -C "$TREE" ARCH=arm64 -j"$(nproc)" M=drivers/regulator modules \
	KBUILD_MODPOST_WARN=1 > "$log" 2>&1 || {
	echo "FATAL: build failed"; grep -iE 'error' "$log" | head -10; exit 1; }

ko="$TREE/drivers/regulator/qcom-rpmh-regulator.ko"
[ -f "$ko" ] || { echo "FATAL: no $ko"; exit 1; }

installed=/lib/modules/$V/kernel/drivers/regulator/qcom-rpmh-regulator.ko
echo "== verifying"
printf '  vreg table size : %s bytes (256 = the 7 PMH0104 rails + terminator)\n' \
	"$(readelf -sW "$ko" | awk '$8=="pmh0104_vreg_data"{print $3}')"
printf '  vermagic        : %s\n' "$(modinfo -F vermagic "$ko")"
printf '  module_layout   : %s  (installed: %s)\n' \
	"$(modprobe --dump-modversions "$ko" | awk '$2=="module_layout"{print $1}')" \
	"$(modprobe --dump-modversions "$installed" | awk '$2=="module_layout"{print $1}')"
printf '  srcversion      : %s  (installed: %s)\n' \
	"$(modinfo -F srcversion "$ko")" "$(modinfo -F srcversion "$installed")"

[ "$(modinfo -F vermagic "$ko")" = "$(modinfo -F vermagic "$installed")" ] \
	|| { echo "FATAL: vermagic differs from the installed module"; exit 1; }
[ "$(modprobe --dump-modversions "$ko" | awk '$2=="module_layout"{print $1}')" \
	= "$(modprobe --dump-modversions "$installed" | awk '$2=="module_layout"{print $1}')" ] \
	|| { echo "FATAL: module_layout CRC differs"; exit 1; }
[ "$(readelf -sW "$ko" | awk '$8=="pmh0104_vreg_data"{print $3}')" = 256 ] \
	|| { echo "FATAL: the vreg table does not have the 7 rails"; exit 1; }

cp -f "$ko" "$out/qcom-rpmh-regulator.ko"
sha256sum "$out/qcom-rpmh-regulator.ko" > "$out/qcom-rpmh-regulator.ko.sha256"
echo "== staged"
cat "$out/qcom-rpmh-regulator.ko.sha256"
echo "   log: $log"
echo "   next: sudo bash $cam/a16-camera-step2.sh --check"
