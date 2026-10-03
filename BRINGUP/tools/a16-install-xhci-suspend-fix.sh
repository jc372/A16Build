#!/usr/bin/env bash
# a16-install-xhci-suspend-fix.sh -- install the patched xhci-plat-hcd.ko (the lid/suspend fix).
#
#   type this:   sudo bash ~/a16.sh suspendfix            # install it, then it says to reboot
#                bash ~/a16.sh suspendfix status         # what is installed, and is it the loaded one
#                sudo bash ~/a16.sh suspendfix revert     # remove it (back to the stock module)
#
# What it installs, and why.  On this board the *second and every later* system suspend of a boot
# aborts, because the USB core does not leave this HCD bus-suspended and xhci_suspend() returns
# -EINVAL:
#
#   xhci-hcd xhci-hcd.1.auto: PM: dpm_run_callback(): platform_pm_suspend returns -22
#   xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
#   PM: Some devices failed to suspend, or early wake event detected
#
# so the whole system suspend fails, logind retries it every ~33 s while the lid is shut, and the
# machine stays awake (~6-7 W, ~10 %/h).  xhci-plat-hcd.ko is the only piece of that path that is a
# loadable module here, so the workaround lives in it: when xhci_suspend() returns -EINVAL because the
# HCD was never suspended, leave the controller running instead of failing the system suspend, remind
# it on the resume half, and log the hcd/root-hub states at every transition.
#
# Patch: BRINGUP/patches/0010-xhci-plat-a16-skip-unsuspended-hcd.patch
# Built from: ~/build/linux-next-1a1de54f7369 (native, same tree/config as the running kernel)
# Module parameters (live, either direction):
#   /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd   the fix, 1 = on (default)
#   /sys/module/xhci_plat_hcd/parameters/a16_state_log              the state log, 1 = on (default)
set -u

MODE="${1:-install}"
KVER="$(uname -r)"
KO="${A16_XHCI_KO:-/home/jc/build/linux-next-1a1de54f7369/drivers/usb/host/xhci-plat-hcd.ko}"
STOCK="/lib/modules/$KVER/kernel/drivers/usb/host/xhci-plat-hcd.ko"
DEST_DIR="/lib/modules/$KVER/updates/a16"
DEST="$DEST_DIR/xhci-plat-hcd.ko"
LOG="${A16_LOG:-/home/jc/a16-payload/xhci-suspendfix-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

loaded_srcversion()  { cat /sys/module/xhci_plat_hcd/srcversion 2>/dev/null; }
file_srcversion()    { modinfo -F srcversion "$1" 2>/dev/null; }
file_vermagic()      { modinfo -F vermagic "$1" 2>/dev/null; }
crcs()               { modprobe --dump-modversions "$1" 2>/dev/null | sort; }

say "=== a16-install-xhci-suspend-fix  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
say "kernel: $KVER   boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "log   : $LOG"

case "$MODE" in
  status)
    rule
    say "-- what is where"
    printf '   %-58s %s\n' "stock module" "$([ -f "$STOCK" ] && echo "present (srcversion $(file_srcversion "$STOCK"))" || echo missing)"
    printf '   %-58s %s\n' "installed override ($DEST)" \
      "$([ -f "$DEST" ] && echo "present (srcversion $(file_srcversion "$DEST"))" || echo 'not installed')"
    printf '   %-58s %s\n' "loaded now" "srcversion $(loaded_srcversion)"
    rule
    say "-- the module parameters (absent = stock module is loaded)"
    for p in a16_skip_unsuspended_hcd a16_state_log; do
      printf '   %-58s %s\n' "$p" "$(cat "/sys/module/xhci_plat_hcd/parameters/$p" 2>/dev/null || echo 'n/a')"
    done
    rule
    if [ ! -f "$DEST" ]; then
      say "The fix is not installed.  Install it with:   sudo bash ~/a16.sh suspendfix"
    elif [ "$(loaded_srcversion)" = "$(file_srcversion "$DEST")" ]; then
      say "The patched module is installed AND loaded: the fix is active in this boot."
      say "Test it with:   sudo lid_sleep test 2      (both attempts should sleep)"
    else
      say "The patched module is installed but NOT loaded (the loaded srcversion is the stock one):"
      say "reboot for it to take effect, then run:   sudo lid_sleep test 2"
    fi
    say ""
    say "log: $LOG"
    exit 0 ;;
  install|revert) ;;
  *) say "usage: bash $0 [install|status|revert]"; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || [ "${A16_SKIP_ROOT:-0}" = 1 ] || {
  say "This needs root.  Type exactly:"
  say ""
  say "    sudo bash ~/a16.sh suspendfix${1:+ $1}"
  say ""
  exit 1; }

if [ "$MODE" = revert ]; then
  rule
  if [ -f "$DEST" ]; then
    rm -f "$DEST" && say "   removed $DEST" || { say "   could not remove $DEST"; exit 1; }
    depmod -a "$KVER" && say "   depmod -a $KVER done"
    say ""
    say "The stock module is what loads from now on.  Reboot to drop the patched one from the running"
    say "kernel (it stays loaded until then)."
  else
    say "   $DEST was not there -- nothing to revert"
  fi
  say ""
  say "log: $LOG"
  exit 0
fi

# ------------------------------------------------------------------ install
rule
say "-- checking the module to install"
[ -f "$KO" ] || { say "   $KO is missing -- build it first:"; say "     (see BRINGUP/patches/0010-*.patch and tools/a16-build-gpucc-native.sh)"; exit 1; }
say "   file          : $KO"
say "   built         : $(date -r "$KO" '+%Y-%m-%d %H:%M:%S')   $(stat -c %s "$KO") bytes"

if strings "$KO" | grep -q 'A16: the USB core left this HCD unsuspended'; then
  say "   carries the fix: yes (the A16 message is in the module)"
else
  say "   carries the fix: NO -- this is not the patched module, refusing to install it"
  exit 1
fi

vm="$(file_vermagic "$KO")"
if [ "$vm" = "$(file_vermagic "$STOCK")" ]; then
  say "   vermagic      : $vm  (= the kernel's)"
else
  say "   vermagic      : $vm"
  say "   kernel's      : $(file_vermagic "$STOCK")"
  say "   refusing: a mismatched vermagic does not load."
  exit 1
fi

# Every symbol the stock module imports must still be imported with the same CRC: that is the ABI
# check that matters (module_layout included -- it is one of the imports).
missing=$(comm -23 <(crcs "$STOCK") <(crcs "$KO"))
if [ -z "$missing" ]; then
  say "   imports       : every symbol the stock module imports matches ($(crcs "$KO" | wc -l) imports, module_layout $(grep -m1 module_layout <(crcs "$KO") | cut -f1))"
else
  say "   imports       : MISMATCH -- these are in the stock module but not identically in the new one:"
  printf '%s\n' "$missing" | sed 's/^/      /'
  say "   refusing: that means the module was not built against this kernel's config/tree."
  exit 1
fi

rule
say "-- installing into $DEST_DIR (updates/ wins over kernel/ in depmod)"
mkdir -p "$DEST_DIR" || exit 1
cp -f "$KO" "$DEST" || exit 1
say "   copied: $(file_srcversion "$DEST") -> $DEST   (stock was $(file_srcversion "$STOCK"))"
chmod 644 "$DEST"
depmod -a "$KVER" && say "   depmod -a $KVER done"

rule
say "Next: reboot (the module is loaded already, so it has to come from a fresh boot), then:"
say ""
say "    sudo lid_sleep test 2"
say ""
say "What to look for: both attempts should say VERDICT: slept, and the log will carry the A16 lines"
say "   A16 suspend: hcd state=2 flags=0x41 root_hub=7 | shared state=2 root_hub=7 | wakeup=0 quirks=0x..."
say "   A16: the USB core left this HCD unsuspended (state=2, shared=2) -- leaving the controller running"
say "which name the state that xhci_suspend() objects to (7 = USB_STATE_CONFIGURED, 8 = SUSPENDED).  Undo any time:"
say ""
say "    sudo bash ~/a16.sh suspendfix revert"
say ""
say "log: $LOG"
