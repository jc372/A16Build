#!/usr/bin/env bash
# a16-build-gpucc-module.sh -- build the one module the installed kernel is missing, on the BUILD
#                              side (WSL or the Tumbleweed VM), and package it for the A16.
#
#   bash a16-build-gpucc-module.sh [path-to-linux-next-tree]
#   A16_TREE=/path/to/tree bash a16-build-gpucc-module.sh
#
# Why: the installed kernel (7.3.0-rc3-next-20260914) was built with
#      # CONFIG_CLK_GLYMUR_GPUCC is not set
# while every other Glymur clock controller is =m (gcc, dispcc, videocc, camcc, evacc, tcsrcc).  The
# machine DTB's `clock-controller@3d90000 { compatible = "qcom,glymur-gpucc" }` therefore has no
# driver, the GPU's power domain never registers, and the chain dies:
#
#   adreno 3d00000.gpu: deferred probe timeout -> supply vdd not found (dummy) -> bind -19
#   arm-smmu 3da0000.iommu: probe failed -110          (its clock comes from gpucc)
#   gxclkctl-kaanapali 3d64000: probe failed -110      (its power domain is gpucc)
#   msm_dpu ae01000.display-controller: failed to load adreno gpu / failed to bind ... -19
#   -> msm (the DRM/KMS driver) never binds -> no card0 -> the panel stays on the firmware
#      framebuffer -> no brightness device, no refresh-rate modes, no DP.  That is the black screen
#      in entries [3]/[4].
#
# This is a module-only build: same tree, same .config (plus the one symbol), same Module.symvers,
# so the module's vermagic and CRCs match the running kernel.  Nothing else is rebuilt.
set -u

TREE="${1:-${A16_TREE:-/home/jc/A16Build/local-wsl-build/linux-next}}"
VER="${A16_KVER:-7.3.0-rc3-next-20260914}"
WANT_VERMAGIC="$VER SMP preempt mod_unload modversions aarch64"
OUT="${A16_OUT:-/home/jc/a16-export}"
CROSS="${A16_CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${A16_ARCH:-arm64}"
MOD=gpucc-glymur

say() { printf '%s\n' "$*"; }
die() { say "FATAL: $*"; exit 1; }

say "=== a16-build-gpucc-module $(date +%Y%m%d-%H%M%S) ==="
say "tree : $TREE"
[ -d "$TREE" ] || die "no tree at $TREE (pass the linux-next tree path, or set A16_TREE)"
[ -f "$TREE/.config" ] || die "$TREE/.config missing -- that is not a configured kernel tree"
[ -f "$TREE/Module.symvers" ] || die "$TREE/Module.symvers missing -- the tree must have been built at least once (modules + modversions need it)"
[ -x "$TREE/scripts/config" ] || die "$TREE/scripts/config missing"

if ! grep -q 'CLK_GLYMUR_GPUCC' "$TREE/drivers/clk/qcom/Kconfig"; then
  die "drivers/clk/qcom/Kconfig has no CLK_GLYMUR_GPUCC -- this tree predates the Glymur GPUCC driver; the kernel itself has to be rebased"
fi
say "kconfig: CLK_GLYMUR_GPUCC exists in the tree ✓"
say ""
say "before: $(grep -E '^#? ?CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config" || echo '(symbol absent from .config)')"

cp -a "$TREE/.config" "$TREE/.config.a16-gpucc-bak" 2>/dev/null || true
"$TREE/scripts/config" --file "$TREE/.config" --module CLK_GLYMUR_GPUCC || die "scripts/config failed"
say "after : $(grep -E '^#? ?CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config")"

say ""
say "== prepare + build just drivers/clk/qcom =="
make -C "$TREE" ARCH="$ARCH" CROSS_COMPILE="$CROSS" olddefconfig >/dev/null 2>&1 || say "   (olddefconfig warned; continuing)"
make -C "$TREE" ARCH="$ARCH" CROSS_COMPILE="$CROSS" M=drivers/clk/qcom modules 2>&1 | tail -12 || die "module build failed (see above)"

KO="$TREE/drivers/clk/qcom/$MOD.ko"
[ -f "$KO" ] || die "$KO was not produced"
got="$(modinfo -F vermagic "$KO" 2>/dev/null)"
say ""
say "built : $KO ($(stat -c %s "$KO") bytes)"
say "sha256: $(sha256sum "$KO" | cut -c1-32)…"
say "vermagic: $got"
case "$got" in
  "$WANT_VERMAGIC") say "vermagic matches the running kernel ✓" ;;
  *) say "WARNING: vermagic is '$got' but the A16 expects '$WANT_VERMAGIC'."
     say "         A mismatched version/SMP/PREEMPT/MODVERSIONS flag means the module will refuse to load." ;;
esac

mkdir -p "$OUT" || die "cannot create $OUT"
PKG="$OUT/$MOD-$VER.tar.gz"
tar -czf "$PKG" -C "$TREE/drivers/clk/qcom" "$MOD.ko" || die "tar failed"
sha256sum "$PKG" > "$PKG.sha256"
say ""
say "packaged: $PKG ($(stat -c %s "$PKG") bytes)"
say "          $PKG.sha256"
say ""
say "== on the A16 =="
say "  copy $PKG over (stick, scp, or the repo), then:"
say "    sudo bash /home/jc/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh $PKG"
say "    reboot, take entry [3], wait ~90 s, then read the snapshot:"
say "      ls -t ~/a16-payload/boots | head -1"
say ""
say "what success looks like in that snapshot's dmesg:"
say "  gpucc-glymur 3d90000.clock-controller: registered   (or similar bind line)"
say "  adreno 3d00000.gpu: ... GMU firmware  /  bound"
say "  msm_dpu ae01000.display-controller: bound ... -> a /dev/dri/card0 driven by *msm*"
say "  /sys/class/backlight/<panel> exists -> brightness slider + refresh-rate modes"
say ""
say "NOTE: with the display up, entries [3]/[4] stop being black-screen entries; [2], which"
say "      blacklists msm, remains the fallback until the display path is trusted."
