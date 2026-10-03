#!/usr/bin/env bash
# a16-stage-phy-v8fix-test.sh -- put the *posted upstream* v8 eDP PHY fix on the machine as the one
#                                  and only PHY module, strip our own experiments, and set entry [3]
#                                  up for a test whose result cannot be misread.
#
#   sudo bash a16-stage-phy-v8fix-test.sh          # stage it
#   sudo bash a16-stage-phy-v8fix-test.sh --check  # read-only: what is in place right now?
#
# Why this shape:
#   * The fix is Bjorn Andersson's `phy: qcom: edp: Update v8 programming sequence` (2026-06-22,
#     patchwork series 1114965, changes-requested, in no kernel).  Our panel's maximum is HBR2
#     (5.4 Gbps) -- the rate the current v8 sequence gets wrong -- so 4-lane HBR2 link training
#     fails in channel equalization exactly as we see.  Already fetched and built by the other
#     session as ~/a16-payload/phy-qcom-edp-v8fix.ko (vermagic exact, module_layout CRC 0xe6658f7b).
#   * A module named `phy-qcom-edp-v8fix.ko` declares the same OF alias as `phy-qcom-edp.ko`, so two
#     modules compete for one device and which one binds depends on alias ordering.  This script
#     removes the ambiguity: the fix is installed *as* phy-qcom-edp.ko, and our own two experiment
#     modules are taken out, so the only change from stock is the upstream fix.
#   * The panel is proven to show the boot console on the firmware framebuffer, and GNOME then blanks
#     the screen (fb0 blank=4) -- which is indistinguishable from a failed test.  So entry [3] is set
#     to a text console (`systemd.unit=multi-user.target`) with `drm.debug` and `consoleblank=0`,
#     which never blanks: if the link trains you *see* the console, if it does not you see it go dark
#     once.  (`consoleblank` defaults to 600 s in the kernel, so even a text console goes black after
#     ten idle minutes -- that is the other half of why a working boot kept looking broken.)
set -u

KVER="$(uname -r)"
UPD="/lib/modules/$KVER/updates/a16"
FIX_SRC="${A16_FIX_SRC:-/home/jc/a16-payload/phy-qcom-edp-v8fix.ko}"
MSM_KO="${A16_MSM_KO:-/home/jc/build/linux-next-1a1de54f7369/drivers/gpu/drm/msm/msm.ko}"
INSTALLER="/home/jc/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh"
TOOL="/home/jc/A16Build/BRINGUP/tools/a16-drm-debug-entry.sh"
PARAMS="drm.debug=0x1ff systemd.unit=multi-user.target consoleblank=0"
say() { printf '%s\n' "$*"; }

show_state() {
  say "module the panel's PHY will bind (of:N*T*Cqcom,glymur-dp-phy):"
  grep -m2 'glymur-dp-phy ' /lib/modules/$KVER/modules.alias 2>/dev/null | sed 's/^/   /'
  say "what 'phy-qcom-edp' resolves to : $(modinfo -F filename phy-qcom-edp 2>/dev/null || echo '(none)')"
  say "what 'msm' resolves to         : $(modinfo -F filename msm 2>/dev/null || echo '(none)')"
  say "what 'gpucc-glymur' resolves to: $(modinfo -F filename gpucc-glymur 2>/dev/null || echo '(none)')"
  say "files in $UPD:"
  ls -la "$UPD" 2>/dev/null | awk 'NR>3 {printf "   %s  %s\n", $5, $9}'
  say "entry [3] parameters now:"
  grep -m1 'linux /boot/vmlinuz' /boot/efi/a16boot/grub.cfg | tr ' ' '\n' | grep -E 'drm.debug|video=|systemd.unit|acpi=off' | sed 's/^/   /'
}

if [ "${1:-}" = "--check" ]; then
  say "=== a16-stage-phy-v8fix-test --check ==="
  show_state
  exit 0
fi

[ "$(id -u)" = 0 ] || { say "needs root: sudo bash $0"; exit 1; }

say "=== a16-stage-phy-v8fix-test $(date +%Y%m%d-%H%M%S) ==="
say ""
say "1. verify the fix artifact before it replaces anything"
[ -f "$FIX_SRC" ] || { say "   FATAL: $FIX_SRC is missing"; exit 1; }
WANT="$(modinfo -F vermagic /lib/modules/$KVER/kernel/drivers/phy/qualcomm/phy-qcom-edp.ko 2>/dev/null)"
GOT="$(modinfo -F vermagic "$FIX_SRC" 2>/dev/null)"
KML="$(modprobe --dump-modversions /lib/modules/$KVER/kernel/drivers/phy/qualcomm/phy-qcom-edp.ko | awk '$2=="module_layout"{print $1}')"
FML="$(modprobe --dump-modversions "$FIX_SRC" | awk '$2=="module_layout"{print $1}')"
say "   source    : $FIX_SRC ($(stat -c %s "$FIX_SRC") bytes, sha256 $(sha256sum "$FIX_SRC" | cut -c1-24)…)"
say "   vermagic  : $GOT   (kernel: $WANT)"
say "   module_layout: $FML   (kernel: $KML)"
[ "$GOT" = "$WANT" ] && [ "$FML" = "$KML" ] || { say "   FATAL: this module would be refused; not installing"; exit 1; }
say "   carries the v8 symbols: $(strings -a "$FIX_SRC" | grep -cE 'qcom_edp_prepare_power_on_v8|qcom_edp_finish_power_on_v8|qcom_edp_ldo_config_v8|qcom_edp_configure_tx_pre_pll_v8_lane') of 4"
say ""

say "2. install it as phy-qcom-edp.ko (one module per alias, no ordering lottery)"
install -d -m 0755 "$UPD"
install -m 0644 "$FIX_SRC" "$UPD/phy-qcom-edp.ko" && say "   installed: $UPD/phy-qcom-edp.ko"
for stale in phy-qcom-edp-v8fix.ko msm.ko; do
  if [ -f "$UPD/$stale" ]; then rm -f "$UPD/$stale" && say "   removed  : $UPD/$stale (our own experiment)"; fi
done
say "   kept     : gpucc-glymur.ko (required: without it msm cannot bind at all)"
depmod -a "$KVER" 2>&1 | sed 's/^/   depmod: /'
say ""

say "2b. the rebuilt msm.ko: force the eDP link rate to HBR3 -- the rate that trains this panel"
if [ -f "$MSM_KO" ]; then
  say "   source: $MSM_KO ($(stat -c %s "$MSM_KO") bytes, built $(stat -c %y "$MSM_KO" | cut -c1-19))"
  if strings -a "$MSM_KO" | grep -q 'A16 experiment: channel equalization'; then
    say "   WARNING: this msm.ko still carries the channel-equilization hack; the rate test wants it"
    say "            reverted (rebuild from the tree with dp_ctrl.c pristine)"
  fi
  bash "$INSTALLER" "$MSM_KO" 2>&1 | grep -E 'vermagic|module_layout|installed |resolvable|FATAL|dry-run|imports' | sed 's/^/   /'
else
  say "   (no $MSM_KO -- the link-rate change is not in play; stock msm will run)"
fi
say ""

say "3. entry [3]: text console, no console blanking, DRM debug on, and NO forced 60 Hz (the fix's
   working case is 4-lane HBR2, which is what the panel's 120 Hz mode uses -- pinning 60 Hz was the
   opposite of the test)"
A16_PARAMS="$PARAMS" bash "$TOOL" remove inline >/dev/null 2>&1
A16_PARAMS="$PARAMS" bash "$TOOL" arm 2>&1 | sed 's/^/   /'
say ""

say "4. state to expect on the next boot"
show_state
say ""
say "NEXT: boot [3].  On the panel you should see the kernel log scroll by and then STOP SCROLLING"
say "WITHOUT GOING DARK -- that is the text console, i.e. the link trained.  If the screen goes black"
say "once and stays black, the fix did not train the link on this unit and I will read:"
say "    sudo journalctl -k -b -1 | grep -E 'link training #[12]|A16 experiment'"
say "Reverting to stock: rm $UPD/phy-qcom-edp.ko && sudo depmod -a   (keeps gpucc-glymur.ko)"
