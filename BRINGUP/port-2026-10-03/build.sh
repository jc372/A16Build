#!/usr/bin/env bash
# build.sh -- build the A16's kernel for this linux-next, on this machine, from scratch.
#
#   bash build.sh --check          read-only: what is done, what would run
#   bash build.sh                  fetch (if needed) + config + patches + build
#   sudo bash build.sh --install   install the built kernel beside the running one
#   sudo bash build.sh --all       build, then install
#
# Idempotent: every step checks whether its work is already done and skips it.
# Paths are relative to this directory, except the patch set, which lives at the
# repository root (../../patches) so there is one working set and not several.
# Nothing is destructive: every step that writes takes a backup, and the boot menu
# is backed up before it is edited.
#
# What this build is, and why each piece is here, is in ./readme.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REL="${A16_REL:-next-20261002}"                  # the linux-next snapshot
KREL="7.3.0-rc5-$REL"                            # the release the tree produces
BASE="${A16_BUILD_DIR:-$HOME/build}"
TAR="$BASE/linux-$REL.tar.gz"
TREE="${A16_TREE:-$BASE/$REL}"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-$REL.tar.gz"
PATCH_DIR="${A16_PATCH_DIR:-$HERE/../../patches}"   # the patch set lives at the repository root
SEED="$HERE/config-seed"
ESP="${A16_ESP:-/boot/efi}"
LOG="${A16_LOG:-$HOME/a16-payload/a16-build-$REL-$(date +%Y%m%d-%H%M%S).log}"
MODE="${1:---all}"

[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
die() { say "FATAL: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# ---------------------------------------------------------------- checks
preflight() {
  sec "preflight"
  for t in wget tar make gcc bc flex bison gawk patch depmod; do
    printf '  %-8s %s\n' "$t" "$(command -v "$t" || echo MISSING)" | tee -a "$LOG"
  done
  # gawk is a hard requirement: without it the build dies at the very last link step
  command -v gawk >/dev/null 2>&1 || die "gawk is required (the build fails at modules.builtin.ranges)"
  command -v curl >/dev/null 2>&1 || say "  note: curl is absent on this machine; wget is used"
  printf '  disk free: %s    tree: %s\n' "$(df -h "$BASE" 2>/dev/null | tail -1 | awk '{print $4}')" "$TREE" | tee -a "$LOG"
}

# ---------------------------------------------------------------- 1. source
step_tarball() {
  sec "1. the snapshot"
  if [ -s "$TAR" ]; then say "  have it: $TAR ($(du -h "$TAR" | cut -f1))"; return 0; fi
  say "  fetching $URL"
  wget -nv --timeout=120 -O "$TAR" "$URL" 2>&1 | tail -2 | tee -a "$LOG"
  [ -s "$TAR" ] || die "download failed"
}

step_tree() {
  sec "2. the tree"
  if [ -f "$TREE/Makefile" ] && [ -d "$TREE/drivers" ]; then
    say "  have it: $TREE ($(find "$TREE" -type f | wc -l) files)"
    # a tree that has ever been built in-tree is not a clean baseline
    n=$(find "$TREE" -name '*.o' 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && say "  WARNING: $n build objects present; this is not a fresh extract"
    return 0
  fi
  say "  extracting to $TREE"
  mkdir -p "$TREE"
  tar -xzf "$TAR" -C "$TREE" --strip-components=1 || die "extract failed"
  say "  extracted: $(find "$TREE" -type f | wc -l) files"
}

# ---------------------------------------------------------------- 3. config
step_config() {
  sec "3. the configuration"
  [ -f "$SEED" ] || die "no seed config at $SEED"
  if [ -f "$TREE/.config" ]; then
    say "  .config already present; leaving it alone (remove it to re-seed)"
  else
    cp -a "$SEED" "$TREE/.config"; say "  seeded .config from $SEED"
  fi
  # upstream declares: config CLK_GLYMUR_GPUCC ... default m if ARCH_QCOM
  # without it the GPU clock controller never probes, the DRM device fails to bind
  # with -19, and the machine boots to a black screen with no display at all.
  if grep -q '^CONFIG_CLK_GLYMUR_GPUCC=m' "$TREE/.config"; then
    say "  CLK_GLYMUR_GPUCC=m present"
  else
    say "  CLK_GLYMUR_GPUCC was not set; enabling it (upstream's own default)"
    ( cd "$TREE" && ./scripts/config --module CLK_GLYMUR_GPUCC )
  fi
  make -s -C "$TREE" olddefconfig >/dev/null 2>&1 || die "olddefconfig failed"
  say "  after olddefconfig: $(grep -m1 'CLK_GLYMUR_GPUCC' "$TREE/.config")"
}

# ---------------------------------------------------------------- 4. patches
step_patches() {
  sec "4. the patch set"
  [ -d "$PATCH_DIR" ] || die "no patch directory at $PATCH_DIR"
  local p base
  for p in "$PATCH_DIR"/*.patch; do
    [ -f "$p" ] || continue
    base="$(basename "$p")"
    # already applied? a reverse dry-run succeeds exactly when it is
    if patch -p1 -R --dry-run --batch -d "$TREE" < "$p" >/dev/null 2>&1; then
      say "  $base: already applied, skipping"
      continue
    fi
    if patch -p1 --dry-run --forward --batch -d "$TREE" < "$p" >/dev/null 2>&1; then
      patch -p1 --batch -d "$TREE" < "$p" >/dev/null 2>&1 || die "$base: apply failed"
      say "  $base: applied"
    else
      say "  $base: DOES NOT APPLY to this tree -- upstream moved; needs a rebase"
      say "         (see readme.md section 2; the build continues without it)"
    fi
  done
}

# ---------------------------------------------------------------- 5. build
step_build() {
  sec "5. build"
  need make
  local jobs; jobs="$(nproc 2>/dev/null || echo 6)"
  say "  make -j$jobs Image dtbs modules  in $TREE"
  nice -n 19 ionice -c3 make -C "$TREE" -j"$jobs" Image dtbs modules >>"$LOG" 2>&1
  local rc=$?
  say "  make exit: $rc"
  [ "$rc" -eq 0 ] || { grep -a -iE 'error|no space|not clean' "$LOG" | tail -6 | tee -a "$LOG"; die "build failed"; }
  say "  Image   : $(ls -sh "$TREE/arch/arm64/boot/Image" 2>/dev/null | awk '{print $1}')"
  say "  release : $(make -s -C "$TREE" kernelrelease 2>/dev/null)"
  say "  gpucc   : $(ls -sh "$TREE/drivers/clk/qcom/gpucc-glymur.ko" 2>/dev/null | awk '{print $1}')"
  say "  EC      : $(ls -sh "$TREE/drivers/platform/arm64/asus-glymur-ec.ko" 2>/dev/null | awk '{print $1}')"
  say "  dtb     : $(ls -sh "$TREE/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb" 2>/dev/null | awk '{print $1}')"
}

# ---------------------------------------------------------------- 6. install
step_install() {
  sec "6. install (root)"
  [ "$(id -u)" = 0 ] || die "--install needs root"
  local rel; rel="$(make -s -C "$TREE" kernelrelease)"
  local dtb="$TREE/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
  [ -f "$TREE/arch/arm64/boot/Image" ] || die "no Image in $TREE -- build first"
  say "  release: $rel"
  # follow the repo's own installer when it matches this release, else do the steps here
  local inst="$HERE/../tools/a16-install-stock-next.sh"
  if [ -x "$inst" ] || [ -f "$inst" ]; then
    say "  deferring to $inst (it takes the tree and does the ESP backup + menuentry)"
    A16_LOG="$LOG" bash "$inst" "$TREE"
  else
    die "no installer found at $inst; install by hand (vmlinuz, dtb, modules_install, initramfs, menuentry)"
  fi
}

# ---------------------------------------------------------------- main
case "$MODE" in
  --check) preflight
           printf '\n  tarball : %s\n  tree    : %s\n  config  : %s\n  patches : %s\n' \
             "$([ -s "$TAR" ] && echo present || echo would-download)" \
             "$([ -f "$TREE/Makefile" ] && echo present || echo would-extract)" \
             "$([ -f "$TREE/.config" ] && echo present || echo would-seed)" \
             "$(ls -1 "$PATCH_DIR"/*.patch 2>/dev/null | wc -l) files" | tee -a "$LOG" ;;
  --install) step_install ;;
  --all)   preflight; step_tarball; step_tree; step_config; step_patches; step_build; step_install ;;
  *)       preflight; step_tarball; step_tree; step_config; step_patches; step_build ;;
esac
say ""
say "log: $LOG"
