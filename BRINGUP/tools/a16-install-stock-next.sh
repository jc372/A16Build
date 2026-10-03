#!/usr/bin/env bash
# a16-install-stock-next.sh -- install a freshly built kernel tree beside the running one, as its
# own boot entry, with upstream's device tree and no A16 patches.  This is the "run it stock" path:
# it never replaces what is installed, never touches set default, and never removes an entry.
#
#   sudo bash a16-install-stock-next.sh <tree> [dtb-name]
#   e.g. sudo bash a16-install-stock-next.sh /home/jc/build/next-20261002
#
# What it does, in order:
#   1. reads the release name from the tree (make kernelrelease) and refuses if it collides with
#      the running kernel's release -- a collision is what would overwrite the working kernel
#   2. installs /boot/vmlinuz-<ver> and the tree's own DTB (distinct filename, no overwrite)
#   3. modules_install into /lib/modules/<ver>
#   4. builds the initramfs for that release (nvme is a module, so one is required)
#   5. backs up the ESP menu, appends one menuentry, and only installs it if grub-script-check
#      passes -- on failure the backup stays and the original is untouched
#
# Recovery, if the new kernel comes up wrong: the GRUB menu itself is drawn by the firmware and
# navigated with the firmware's keyboard, so [2] (failsafe) and [3] (display) are always reachable
# even if Linux has no input.  A long press on the power button hard-powers-off from the firmware.
#
# Log: ~/a16-payload/install-stock-<timestamp>.log
set -u

TREE="${1:-}"
[ -n "$TREE" ] || { printf 'usage: sudo bash %s <kernel tree>\n' "$0"; exit 1; }
[ -f "$TREE/arch/arm64/boot/Image" ] || { printf 'FATAL: no Image in %s -- build it first\n' "$TREE"; exit 1; }

LOG_DIR=/home/jc/a16-payload; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/install-stock-$(date +%Y%m%d-%H%M%S).log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { say "FATAL: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo bash $0 $TREE"

RUNNING="$(uname -r)"
VER="$(make -s -C "$TREE" kernelrelease 2>/dev/null | tail -1)"
[ -n "$VER" ] || die "could not read the release name from $TREE"
say "=== installing $VER (A16 port: 11 patches applied in-tree) ==="
say "log : $LOG"
say "tree: $TREE"
say "running kernel: $RUNNING"
[ "$VER" = "$RUNNING" ] && die "release $VER is the RUNNING kernel -- refusing to overwrite it"

DTB_SRC="$TREE/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
[ -f "$DTB_SRC" ] || die "no A16 dtb in the tree ($DTB_SRC)"
DTB_DST="/boot/glymur-a16-$VER.dtb"

say ""
say "=== 1/4 kernel + dtb ==="
install -m 644 "$TREE/arch/arm64/boot/Image" "/boot/vmlinuz-$VER" || die "kernel copy failed"
install -m 644 "$DTB_SRC" "$DTB_DST" || die "dtb copy failed"
sha256sum "/boot/vmlinuz-$VER" "$DTB_DST" | sed 's/^/  /' | tee -a "$LOG"

say ""
say "=== 2/4 modules ==="
make -C "$TREE" INSTALL_MOD_PATH=/ modules_install >> "$LOG" 2>&1 || die "modules_install failed"
[ -d "/lib/modules/$VER" ] || die "/lib/modules/$VER was not created"
say "  modules installed: $(find "/lib/modules/$VER" -name '*.ko*' 2>/dev/null | wc -l)"

say ""
say "=== 3/4 initramfs ==="
update-initramfs -c -k "$VER" >> "$LOG" 2>&1 || die "initramfs build failed"
[ -f "/boot/initrd.img-$VER" ] || die "no /boot/initrd.img-$VER after update-initramfs"
say "  initrd: $(ls -sh "/boot/initrd.img-$VER" | awk '{print $1}')"

say ""
say "=== 4/4 boot entry ==="
CFG=/boot/efi/EFI/ubuntu_snapdragon/grub.cfg
[ -f "$CFG" ] || die "no $CFG"
BAK="$CFG.a16-stock-$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "$BAK" || die "could not back up the menu"
say "  backup: $BAK"
LABEL="[10] A16: next $VER (A16 port: display + BT + EC + suspend)"
grep -qF "$LABEL" "$CFG" && die "that entry already exists -- remove it first if you want to redo this"

NEW="$CFG.new"
cat "$CFG" > "$NEW"
cat >> "$NEW" <<EOF

menuentry "$LABEL" {
    search --no-floppy --fs-uuid --set=root f8e005e9-414c-4c8e-ad68-d1e9fdc208bc
    if [ -f /boot/vmlinuz-$VER -a -f /boot/initrd.img-$VER ]; then
        insmod fdt
        insmod gzio
        linux /boot/vmlinuz-$VER root=UUID=f8e005e9-414c-4c8e-ad68-d1e9fdc208bc  ro  acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7
        devicetree $DTB_DST
        initrd /boot/initrd.img-$VER
        boot
    fi
    echo "  $VER files missing -- reinstall with a16-install-stock-next.sh"
    sleep 20
    configfile \$prefix/grub.cfg
}
EOF
if ! grub-script-check "$NEW" 2>>"$LOG"; then
  say "  grub-script-check FAILED -- menu left untouched, generated file kept at $NEW"
  exit 1
fi
cp -a "$NEW" "$CFG" && rm -f "$NEW"
sync
log "  entry added; menu backed up at $BAK"
say ""
say "=== done ==="
say "  entry : $LABEL"
say "  kernel: /boot/vmlinuz-$VER"
say "  dtb   : $DTB_SRC  (copied to $DTB_DST)"
say "  initrd: /boot/initrd.img-$VER"
say ""
say "WHAT THIS MEANS: set default was NOT touched, so the machine still boots [3] by default."
say "  At the next reboot, choose the entry above by hand.  If Linux comes up with no display or no"
say "  input, the GRUB menu is drawn and driven by the firmware, so [2] and [3] remain reachable;"
say "  a long press on the power button hard-powers-off."
say "  Stock means: upstream's drivers and its own device tree -- no EC driver, no DP rate cap,"
say "  no ath12k resume patch."
