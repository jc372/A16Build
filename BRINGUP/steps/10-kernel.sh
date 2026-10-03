#!/usr/bin/env bash
# steps/10-kernel.sh -- install the pinned linux-next kernel + modules + the machine DTB, and
#                       write the 9-entry boot menu to the ESP configs.
#
#   sudo bash steps/10-kernel.sh
#
# Needs the payload bundle (see 00-preflight.sh).  Ends with a reboot instruction: the device-tree
# path only exists once the new kernel and the machine DTB are in the boot chain.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRINGUP="$(dirname "$HERE")"; TOOLS="$BRINGUP/tools"
PAYLOAD="${A16_PAYLOAD:-/home/jc/a16-payload}"
BUNDLE="$PAYLOAD/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst"
LOG="${A16_LOG:-$PAYLOAD/A16STEP10-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== step 10: kernel + device tree $(date +%Y%m%d-%H%M%S) ==="
[ "$(id -u)" = 0 ] || { say "   needs root: sudo bash $0"; exit 1; }
[ -f "$BUNDLE" ] || { say "   FATAL: $BUNDLE is missing (see 00-preflight.sh)"; exit 1; }
say "   bundle : $BUNDLE ($(stat -c %s "$BUNDLE") bytes)"
say "   sha256 : $(sha256sum "$BUNDLE" | cut -c1-24)…  (expect 2cb362c251fe31db687f22a2…)"

if [ -d /lib/modules/7.3.0-rc3-next-20260914 ]; then
  say "   /lib/modules/7.3.0-rc3-next-20260914 already present -- skipping the 680 MB module copy"
  say "   (A16_FORCE_MODULES=1 re-installs it)"
fi

say "   running tools/a16-install-next-kernel.sh …"
bash "$TOOLS/a16-install-next-kernel.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
rc=${PIPESTATUS[0]}
say "   a16-install-next-kernel.sh rc=$rc   (log: $(ls -t /boot/efi/A16NEXTKERNEL.LOG $PAYLOAD/A16NEXTKERNEL* 2>/dev/null | head -1))"
[ "$rc" = 0 ] || { say "   FAILED -- read that log and fix before continuing"; say "log: $LOG"; exit $rc; }

say ""
say "   Installed.  What is now in place:"
say "     /boot/vmlinuz-7.3.0-rc3-next-20260914 + initramfs + /boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
say "     /lib/modules/7.3.0-rc3-next-20260914 (the tree the DTB and the panel drivers come from)"
say "     a 9-entry menu in the four ESP configs (a16boot/grub.cfg, EFI/{Boot,ubuntu,ubuntu_snapdragon}/grub.cfg)"
say ""
say "   NEXT: reboot and take a DEVICE-TREE entry.  On this machine entry [1] is the working one:"
say "     [1] 7.2 + glymur DTB, internal input, panel via firmware framebuffer"
say "   Then: bash steps/20-dt-boot.sh"
say "log: $LOG"
