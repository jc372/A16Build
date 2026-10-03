#!/usr/bin/env bash
# a16-install-next-kernel.sh -- install the payload's own kernel
# (7.3.0-rc3-next-20260914, the tree the machine DTB and the glymur/panel
# drivers belong to) next to the installed 7.2.0-5-generic, build its initramfs
# (nvme is a module, so one is required), and install the boot menu that offers
# it.  Nothing installed is removed; the ACPI/7.2 entry stays first and default.
#
#     sudo bash /home/jc/a16-payload/a16-install-next-kernel.sh
#
# Test mode (no root, installs into a fake tree, skips the initramfs):
#     A16_ALLOW_NONROOT=1 A16_BOOTDIR=/tmp/t/boot A16_MODROOT=/tmp/t/lib/modules \
#     A16_ESP=/tmp/fake-esp A16_SKIP_INITRD=1 bash a16-install-next-kernel.sh
#
# Design rules (arm64-laptop-bringup): verify identity before installing, guard
# every step, no `set -e`, print the reason for every skip, write the log to the
# FAT volume so the run is auditable afterwards, and never touch the installed
# system's own /boot/grub/grub.cfg.
set -u

STAGE_DIR="/home/jc/a16-payload"
BUNDLE="${A16_BUNDLE:-$STAGE_DIR/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst}"
BUNDLE_SHA="2cb362c251fe31db687f22a2a521fc6c7866b3116f760420c1b7f380a3bdfa0a"
VER="7.3.0-rc3-next-20260914"
DTB_NAME="glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_SHA="ddb423f8dda683a965c1ffe6c4933d15bd9714dae7e740faf8d306b968056ac2"
BOOTDIR="${A16_BOOTDIR:-/boot}"
MODROOT="${A16_MODROOT:-/lib/modules}"
ESP="${A16_ESP:-/boot/efi}"
CFG_NEXT="$STAGE_DIR/a16-next-grub.cfg"
STAGER="$STAGE_DIR/a16-stage-dt-boot.sh"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"

if [ "$(id -u)" != "0" ] && [ "${A16_ALLOW_NONROOT:-0}" != "1" ]; then
  echo "[a16-next] needs root. Re-run as:"; echo "    sudo bash $0"; exit 1
fi

if touch "$ESP/.a16w" 2>/dev/null; then rm -f "$ESP/.a16w"; LOG="$ESP/A16NEXTKERNEL.LOG"; else LOG="/var/tmp/A16NEXTKERNEL.LOG"; fi
: > "$LOG"
log() { printf '[a16-next] %s\n' "$*" | tee -a "$LOG"; }
run() { local l="$1"; shift; local out st; out="$("$@" 2>&1)"; st=$?; { echo "### \$ $*"; printf '%s\n' "$out"; echo "### exit: $st"; } | tee -a "$LOG"; return $st; }

log "=== a16-install-next-kernel $STAMP (running $(uname -r)) ==="
log "bundle=$BUNDLE"
log "bootdir=$BOOTDIR  modroot=$MODROOT  esp=$ESP"

# ---- 0. tools and space ----------------------------------------------------
for t in tar zstd sha256sum install depmod lsinitramfs; do
  command -v "$t" >/dev/null 2>&1 && log "tool $t: $(command -v $t)" || { log "tool $t MISSING -- aborting"; exit 1; }
done
[ -f "$BUNDLE" ] || { log "bundle $BUNDLE missing -- aborting"; exit 1; }
[ -f "$CFG_NEXT" ] || { log "menu source $CFG_NEXT missing -- aborting"; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/a16-next-XXXXXX" 2>/dev/null || echo /var/tmp/a16-next-$$)"
mkdir -p "$WORK" || { log "no work dir -- aborting"; exit 1; }
log "work=$WORK  (needs ~5 GB; $(df -h "$WORK" | tail -1 | awk '{print $4}') free there)"
log "free: $BOOTDIR $(df -h "$BOOTDIR" 2>/dev/null | tail -1 | awk '{print $4}')  $(dirname "$MODROOT") $(df -h "$(dirname "$MODROOT")" 2>/dev/null | tail -1 | awk '{print $4}')"

# ---- 1. bundle identity ----------------------------------------------------
log "=== bundle identity ==="
GOT="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
log "sha256: $GOT"
log "expect: $BUNDLE_SHA  (from payload sha256sums.txt)"
if [ "$GOT" != "$BUNDLE_SHA" ]; then log "BUNDLE SHA256 MISMATCH -- refusing to install"; exit 1; fi
log "identity OK"

# ---- 2. extract only what gets installed ----------------------------------
log "=== extract ==="
run "extract-kernel-files" tar -xf "$BUNDLE" -C "$WORK" \
    "zenbook-a16-7.3.0-rc3-next-20260914/Image" \
    "zenbook-a16-7.3.0-rc3-next-20260914/dtbs/qcom/$DTB_NAME" \
    "zenbook-a16-7.3.0-rc3-next-20260914/metadata/kernel.config" || { log "extraction failed -- aborting"; exit 1; }
run "extract-modules" tar -xf "$BUNDLE" -C "$WORK" \
    "zenbook-a16-7.3.0-rc3-next-20260914/modules/lib/modules/$VER" || { log "module extraction failed -- aborting"; exit 1; }
SRC="$WORK/zenbook-a16-7.3.0-rc3-next-20260914"
[ -f "$SRC/Image" ] || { log "Image not extracted -- aborting"; exit 1; }
[ -d "$SRC/modules/lib/modules/$VER" ] || { log "modules tree not extracted -- aborting"; exit 1; }
log "Image: $(stat -c %s "$SRC/Image") bytes  sha256 $(sha256sum "$SRC/Image" | cut -c1-32)..."
log "modules tree: $(du -sh "$SRC/modules/lib/modules/$VER" 2>/dev/null | cut -f1), $(find "$SRC/modules/lib/modules/$VER" -name '*.ko' | wc -l) modules"

DTBSRC="$SRC/dtbs/qcom/$DTB_NAME"
[ -f "$DTBSRC" ] || { log "DTB not extracted -- aborting"; exit 1; }
GOTD="$(sha256sum "$DTBSRC" | cut -d' ' -f1)"
log "DTB sha256: $GOTD  expect $DTB_SHA"
[ "$GOTD" = "$DTB_SHA" ] || { log "DTB MISMATCH -- aborting"; exit 1; }

# ---- 3. install kernel, dtb, config, modules -------------------------------
log "=== install into $BOOTDIR and $MODROOT ==="
mkdir -p "$BOOTDIR" 2>/dev/null || { log "cannot create $BOOTDIR -- aborting"; exit 1; }
run "install-vmlinuz" install -m 0644 "$SRC/Image" "$BOOTDIR/vmlinuz-$VER" || { log "installing vmlinuz failed"; exit 1; }
run "install-dtb"     install -m 0644 "$DTBSRC" "$BOOTDIR/$DTB_NAME" || { log "installing dtb failed"; exit 1; }
[ -f "$SRC/metadata/kernel.config" ] && run "install-config" install -m 0644 "$SRC/metadata/kernel.config" "$BOOTDIR/config-$VER"

if [ -d "$MODROOT/$VER" ] && [ "${A16_FORCE_MODULES:-0}" != "1" ]; then
  log "$MODROOT/$VER already exists -- skipping the module copy (680 MB); A16_FORCE_MODULES=1 reinstalls it"
else
  if [ -d "$MODROOT/$VER" ]; then
    log "$MODROOT/$VER exists -- moving aside to $VER.bak-$STAMP"
    mv "$MODROOT/$VER" "$MODROOT/$VER.bak-$STAMP" 2>/dev/null || log "could not move the old tree aside (continuing)"
  fi
  mkdir -p "$MODROOT" 2>/dev/null
  run "install-modules" cp -a "$SRC/modules/lib/modules/$VER" "$MODROOT/$VER" || { log "copying modules failed -- aborting"; exit 1; }
fi

# ---- 4. depmod for the new version ---------------------------------------
log "=== depmod ==="
if [ "$MODROOT" = "/lib/modules" ]; then
  run "depmod" depmod "$VER"
else
  run "depmod-b" depmod -b "$(dirname "$MODROOT")" "$VER"
fi
if [ -s "$MODROOT/$VER/modules.dep" ]; then
  log "modules.dep: $(wc -l < "$MODROOT/$VER/modules.dep") entries; nvme present: $(grep -c 'nvme' "$MODROOT/$VER/modules.dep")"
else
  log "modules.dep missing/empty -- modules will not autoload (continuing so you can see why)"
fi

# ---- 5. initramfs for the new kernel -------------------------------------
log "=== initramfs ==="
INITRD="$BOOTDIR/initrd.img-$VER"
if [ "${A16_SKIP_INITRD:-0}" = "1" ]; then
  log "A16_SKIP_INITRD=1 -> skipped (test mode)"
else
  if command -v update-initramfs >/dev/null 2>&1; then
    run "update-initramfs" update-initramfs -c -k "$VER"
  fi
  if [ ! -s "$INITRD" ] && command -v mkinitramfs >/dev/null 2>&1; then
    log "trying mkinitramfs directly"
    run "mkinitramfs" mkinitramfs -o "$INITRD" "$VER"
  fi
  if [ -s "$INITRD" ]; then
    log "initrd: $(stat -c %s "$INITRD") bytes"
    N=$(lsinitramfs "$INITRD" 2>/dev/null | grep -c 'nvme')
    log "modules containing 'nvme' inside the initrd: $N  (0 means it will not find the root fs)"
  else
    log "NO INITRAMFS was produced -- the next-kernel entries will not boot the root fs."
    log "  retry by hand: sudo mkinitramfs -o $INITRD $VER"
  fi
fi

# ---- 6. install the boot menu (reuses the stager's backup+verify logic) ----
log "=== boot menu ==="
if [ -f "$STAGER" ]; then
  STAGER_OUT="$(A16_CFG="$CFG_NEXT" A16_ESP="$ESP" bash "$STAGER" 2>&1)"; ST=$?
  printf '%s\n' "$STAGER_OUT" | sed 's/^/[stager] /' | tee -a "$LOG"
  if [ "$ST" = "0" ]; then
    log "menu installed from $CFG_NEXT (stager log: $ESP/A16DTBOOT.LOG)"
  else
    log "STAGER FAILED (exit $ST) -- the ESP menu was NOT updated."
    log "  read $ESP/A16DTBOOT.LOG, fix, and re-run: sudo A16_CFG=$CFG_NEXT bash $STAGER"
  fi
else
  log "stager $STAGER not found -- copy $CFG_NEXT to the ESP by hand"
fi

# ---- 7. summary -----------------------------------------------------------
log "=== summary ==="
for f in "$BOOTDIR/vmlinuz-$VER" "$INITRD" "$BOOTDIR/$DTB_NAME" "$MODROOT/$VER/modules.dep"; do
  if [ -e "$f" ]; then log "  OK      $f ($(stat -c %s "$f") bytes)"; else log "  MISSING $f"; fi
done
log "next boot: pick entry [1] (display left to firmware + internal input) and, if the"
log "panel lights up, entry [2] afterwards (real msm/panel path in the matching tree)."
log "evidence: $ESP/a16-reports/ (a16-boot-report.service writes one set per boot)"
log "rollback: entry [0] (or [3]) boots the installed system exactly as now; nothing"
log "          installed by this script is on the boot path unless you pick [1]/[2]."
log "=== done $STAMP ==="
sync
rm -rf "$WORK" 2>/dev/null && log "work dir removed ($WORK)"
[ "$LOG" != "$STAGE_DIR/A16NEXTKERNEL.LOG" ] && { cp -f "$LOG" "$STAGE_DIR/A16NEXTKERNEL.LOG" 2>/dev/null; chown --reference="$STAGE_DIR" "$STAGE_DIR/A16NEXTKERNEL.LOG" 2>/dev/null; }
echo "[a16-next] log: $LOG"
exit 0
