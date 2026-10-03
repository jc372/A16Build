#!/usr/bin/env bash
# a16-tert-phy-power.sh -- test whether the tert PHY's COM block is simply unpowered.
#
#   type this:                  sudo bash ~/a16.sh tertphy arm           # enable the domain's DT consumer, reboot
#                               sudo bash ~/a16.sh tertphy arm bridge     # + force the domain on from /hdmi-bridge
#                               sudo bash ~/a16.sh tertphy check         # after the reboot: did it change anything?
#                               sudo bash ~/a16.sh tertphy revert        # put the stock DTB back
#                               bash ~/a16.sh tertphy status             # read-only: what is set now
#
# Why.  The tert combo PHY (`88e1000.phy`, the HDMI output) cannot bring up its COM clock:
#
#   gcc_usb3_tert_phy_com_aux_clk status stuck at 'off'   -> clk_bulk_enable fails -> `phy init failed --> -16`
#
# Everything the software can do is demonstrably in place: the rails (including `refgen`, which this
# generation's cfg asks for), the resets, the PHY's own power domain `gcc_usb_2_phy_gdsc` (on), the
# TCSR reference bit, and the parent RCG -- which the neighbouring `aux` branch uses too, and that one
# asserts.  The one thing that is *off* is the instance's controller domain:
#
#   gcc_usb30_tert_gdsc   off      gcc_usb30_sec_gdsc on      gcc_usb30_prim_gdsc on    gcc_usb30_mp_gdsc on
#
# and the register layout agrees that the COM block belongs to it: GDSCR 0xe1010, CBCRs 0xe1070/74/78
# and the RCG 0xe1080 are one page, the same shape as the working `sec` instance at 0xe2010/70/74/78/80.
# A domain is powered by its DT consumer, and the only consumer of `GCC_USB30_TERT_GDSC` is the
# tertiary USB3 controller `usb@a000000` -- which this machine's DTB leaves `disabled`, because the
# board has no USB port on that PHY (it feeds the HDMI bridge).  The other three instances are `okay`
# and their domains are on.
#
# Two levers, in the order they were tried:
#
#   arm         (2026-09-17 11:25) enable `usb@a000000`, the domain's only DT consumer.
#               Result of the reboot that followed: the domain stayed **off**, because that consumer
#               never finished probing -- the journal says
#                 `platform a000000.usb: deferred probe pending: dwc3-qcom: failed to register DWC3 Core`
#               (`dwc3_qcom_probe` -> `dwc3_core_probe`, drivers/usb/dwc3/dwc3-qcom.c:710), i.e. it
#               returned -EPROBE_DEFER out of the same combo PHY that is failing.  Nothing voted.
#
#   arm bridge  additionally give `/hdmi-bridge` (`parade,ps185hdm`, driver `simple-bridge`, always
#               binds) a single `power-domains = <&gcc GCC_USB30_TERT_GDSC>`.  The platform bus calls
#               `dev_pm_domain_attach(dev, true)` before probe, and with exactly one power-domain
#               specifier `genpd_dev_pm_attach()` calls `genpd_power_on()` (drivers/pmdomain/core.c:3411)
#               -- so the domain is forced on at boot with no dependency on any other driver binding.
#               That is why this goes on the bridge and not on the PHY itself: `genpd_dev_pm_attach()`
#               returns 0 immediately for a device with two or more power-domain specifiers
#               (core.c:3457), and `phy@88e1000` already has one.
#               Result (boot 3a63a313, 2026-09-17 12:05): `gcc_usb30_tert_gdsc` **on**, and not one
#               com_aux / `stuck at 'off'` / `phy init failed` line in the boot.  The COM block was
#               only unpowered; the fix is a machine-DTS change, and the remaining question is a
#               monitor (see `display watch`).
#
# The same DTB the firmware ships has `usb@a000000` disabled as well, so the first lever alone is not
# conclusive: the firmware's own power driver can vote a domain without a DT consumer, which a
# DT-driven Linux cannot.  Hence the tests: put a consumer that binds in the DT, reboot, and see
# whether the domain comes on and the COM clock with it.
#
# arm() edits both DTB copies the display entries load (/boot and the ESP twin, which are byte-identical
# here) and writes its own backups -- it never touches the `.a16stock` files the Bluetooth tooling owns.
set -u

MODE="${1:-status}"
LEVER="${2:-usb}"                       # 'usb' (default), 'bridge' (usb + force the domain on)
DEFAULT_FILES="/boot/glymur-asus-zenbook-a16-ux3607oa.dtb:/boot/efi/a16boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
FILES="${A16_DT_FILES:-$DEFAULT_FILES}"
FILES_LIST=$(printf '%s' "$FILES" | tr ':' ' ')   # colon-separated on the command line, one path per word
NODE="/soc@0/usb@a000000"
GCC_NODE="/soc@0/clock-controller@100000"
BRIDGE_NODE="/hdmi-bridge"
TERT_GDSC_ID=18                          # GCC_USB30_TERT_GDSC (include/dt-bindings/clock/qcom,glymur-gcc.h)
BAK_SUFFIX=".a16-tertphy-bak"
LOG="${A16_LOG:-/home/jc/a16-payload/tert-phy-power-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

live() { tr -d '\0' < "/proc/device-tree${1}/status" 2>/dev/null || echo "<no live node>"; }
dt_raw() { od -An -tx1 "/proc/device-tree${1}/$2" 2>/dev/null | tr -d ' \n'; }
file_status() { fdtget "$1" "${2:-$NODE}" status 2>/dev/null || echo "<no such node>"; }
expected_pd() {   # what the domain specifier must look like: take it from the usb node if it is there
  local f=$1 v
  v=$(fdtget "$f" "$NODE" power-domains 2>/dev/null)
  if [ -z "$v" ]; then
    local ph; ph=$(fdtget "$f" "$GCC_NODE" phandle 2>/dev/null) || return 1
    [ -n "$ph" ] || return 1
    v="$ph $TERT_GDSC_ID"
  fi
  printf '%s' "$v"
}

case "$MODE" in
  status) ;;
  arm|revert|check) [ "$(id -u)" = 0 ] || [ "${A16_SKIP_ROOT:-0}" = 1 ] || { say "This needs root. Type exactly:"; say ""; say "    sudo bash ~/a16.sh tertphy $MODE"; say ""; exit 1; } ;;
  *) say "usage: bash $0 [status|arm [bridge]|check|revert]"; exit 2 ;;
esac

say "=== a16-tert-phy-power  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE lever=$LEVER ==="
say "kernel     : $(uname -r)   boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "DTB files  : $FILES"
rule

if [ "$MODE" = status ]; then
  say "-- the controller this test enables: $NODE"
  for f in $FILES_LIST; do
    [ -f "$f" ] || { printf '   %-56s <missing>\n' "$f"; continue; }
    printf '   %-56s status=%-9s backup=%s\n' "$f" "$(file_status "$f")" \
      "$( [ -f "$f$BAK_SUFFIX" ] && echo "yes" || echo "no")"
  done
  say "   live DT (what this boot is using)                  status=$(live "$NODE")"
  say "   .a16stock files (owned by the Bluetooth tooling)   $(ls /boot/glymur-*.a16stock /boot/efi/a16boot/glymur-*.a16stock 2>/dev/null | wc -l) present, left alone"
  rule
  say "-- the forced consumer, if any: $BRIDGE_NODE"
  for f in $FILES_LIST; do
    [ -f "$f" ] || continue
    printf '   %-56s power-domains=%s\n' "$f" "$(fdtget "$f" "$BRIDGE_NODE" power-domains 2>/dev/null || echo '<none>')"
  done
  say "   live DT (raw bytes)                                $(dt_raw "$BRIDGE_NODE" power-domains)"
  rule
  say "-- the domain and the clock this is about"
  grep -E 'gcc_usb30_(tert|sec|prim|mp)_gdsc|gcc_usb_2_phy_gdsc' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | sed 's/^/   /' | head
  grep -E 'tert_phy_(com_aux|aux)_clk ' /sys/kernel/debug/clk/clk_summary 2>/dev/null | sed 's/^/   /' | head -4
  rule
  say "arm edits both files (backups: *$BAK_SUFFIX), then the machine has to reboot into entry [3]."
  say "log: $LOG"
  exit 0
fi

do_arm() {
  rule
  say "-- lever 1: backing up (only if no backup exists yet) and setting $NODE status=okay"
  local rc=0
  for f in $FILES_LIST; do
    [ -f "$f" ] || { say "   $f: missing -- skipped"; rc=1; continue; }
    if [ ! -f "$f$BAK_SUFFIX" ]; then cp -a "$f" "$f$BAK_SUFFIX" && say "   backup : $f$BAK_SUFFIX"; else say "   backup : $f$BAK_SUFFIX already exists -- left alone"; fi
    local before after
    before=$(file_status "$f")
    if [ "$before" = okay ]; then say "   $f: already okay"; else
      fdtput -t s "$f" "$NODE" status okay || { say "   $f: fdtput failed"; rc=1; continue; }
      after=$(file_status "$f")
      say "   $f: status $before -> $after"
      [ "$after" = okay ] || rc=1
    fi
  done

  if [ "$LEVER" = bridge ]; then
    rule
    say "-- lever 2: forcing the domain on with a consumer that always binds: $BRIDGE_NODE"
    say "   (single power-domain specifier -> genpd_dev_pm_attach() calls genpd_power_on() at attach)"
    for f in $FILES_LIST; do
      [ -f "$f" ] || { say "   $f: missing -- skipped"; rc=1; continue; }
      local want have after
      want=$(expected_pd "$f") || { say "   $f: cannot determine the domain specifier -- skipped"; rc=1; continue; }
      have=$(fdtget "$f" "$BRIDGE_NODE" power-domains 2>/dev/null)
      if [ "$have" = "$want" ]; then say "   $f: already sets power-domains = $have"; continue; fi
      # shellcheck disable=SC2086  # $want is deliberately two cells: <&gcc GCC_USB30_TERT_GDSC>
      if ! fdtput -t i "$f" "$BRIDGE_NODE" power-domains $want; then say "   $f: fdtput failed"; rc=1; continue; fi
      after=$(fdtget "$f" "$BRIDGE_NODE" power-domains 2>/dev/null)
      say "   $f: $( [ -n "$have" ] && printf '%s -> %s' "$have" "$after" || printf 'set to %s' "$after")   (want $want)"
      [ "$after" = "$want" ] || rc=1
    done
    rule
    say "What it is for: /hdmi-bridge is on this PHY's output path and its driver (simple-bridge) always"
    say "binds, so the platform bus powers the domain at attach -- no dependency on dwc3-qcom, which is"
    say "where lever 1 stalled."
  else
    rule
    say "(lever 1 only.  If that consumer still defers -- it did on 2026-09-17 -- run:"
    say "    sudo bash ~/a16.sh tertphy arm bridge)"
  fi
  rule
  say "Next: reboot and pick entry [3] (the default), then run:"
  say ""
  say "    sudo bash ~/a16.sh tertphy check"
  say ""
  say "What it is for: with the domain requested at boot it should come up -- and if the COM clock was"
  say "only unpowered, gcc_usb3_tert_phy_com_aux_clk comes up with it and the PHY init stops failing."
  say "Revert any time with:  sudo bash ~/a16.sh tertphy revert"
  exit $rc
}

do_revert() {
  rule
  say "-- restoring from the backups (this drops both levers)"
  local rc=0
  for f in $FILES_LIST; do
    if [ ! -f "$f$BAK_SUFFIX" ]; then say "   $f: no backup -- nothing to restore"; continue; fi
    cp -f "$f$BAK_SUFFIX" "$f" && say "   $f: restored ($(file_status "$f"))" || rc=1
  done
  say "Reboot for the restored DTB to take effect."
  exit $rc
}

do_check() {
  rule
  say "-- this boot's DT"
  say "   live $NODE status = $(live "$NODE")"
  say "   live $BRIDGE_NODE power-domains = $(dt_raw "$BRIDGE_NODE" power-domains)"
  say "      (usb node: $(dt_raw "$NODE" power-domains) -- equal means the bridge carries the same domain)"
  say "   $BRIDGE_NODE driver = $(basename "$(readlink -f /sys/bus/platform/devices/hdmi-bridge/driver 2>/dev/null)" 2>/dev/null || echo '<not bound>')"
  say "   boot command line: $(tr -s ' ' < /proc/cmdline)"
  rule
  say "-- the domain (was 'off' before the change)"
  grep -E 'gcc_usb30_(tert|sec|prim|mp)_gdsc|gcc_usb_2_phy_gdsc' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | sed 's/^/   /' | head
  rule
  say "-- the clock (was enable=0 and refused)"
  grep -E 'tert_phy_(com_aux|aux)_clk ' /sys/kernel/debug/clk/clk_summary 2>/dev/null | sed 's/^/   /' | head -4
  rule
  say "-- what the kernel logged this boot about it"
  journalctl -k -b --no-pager -o short-precise 2>/dev/null \
    | grep -E "com_aux|stuck at 'o|phy init failed|combo|usb@a000000|a000000.dwc3|dwc3.*a000000|hdmi-bridge|gcc_usb30_tert|failed to add to PM domain" \
    | head -20 | sed 's/^/   /'
  say "   [(nothing above means no clock failure and no PHY init failure this boot)]"
  rule
  say "-- connectors"
  for c in /sys/class/drm/card*-*; do
    [ -e "$c/status" ] || continue
    printf '   %-14s %s\n' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)"
  done
  rule
  say "How to read it:"
  say "  gcc_usb30_tert_gdsc 'on' and no clock line above -> the COM block was only unpowered: the"
  say "      HDMI/DP path on this PHY can come up, and the fix is a machine-DTS change (a consumer for"
  say "      the domain, or making the domain always-on for this PHY).  Confirm with a monitor:"
  say "      sudo bash ~/a16.sh display watch, over SSH, then plug it in."
  say "  gcc_usb30_tert_gdsc 'on' but the clock still refuses -> the domain was not the blocker, and"
  say "      what is left is what docs/display-outputs.md already names: the upstream combo PHY work."
  say "  gcc_usb30_tert_gdsc still 'off' -> nothing voted for it: either the controller did not probe"
  say '      (check the journal for a000000 -- "dwc3-qcom: failed to register DWC3 Core" means it'
  say "      deferred), or /hdmi-bridge did not attach (see the driver line above; genpd returns"
  say "      -EPROBE_DEFER when it cannot power the domain, so the bridge would be unbound)."
  say ""
  say "log: $LOG"
  exit 0
}

case "$MODE" in
  arm)    do_arm ;;
  revert) do_revert ;;
  check)  do_check ;;
esac
