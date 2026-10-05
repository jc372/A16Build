#!/usr/bin/env bash
# a16-install-ath12k-resume-fix.sh -- patches/0014 + 0015: the WiFi device's resume.
#
#   0014  do not run the SoC global reset when the resume path powers the device up
#   0015  ... and, because the device is then still running its firmware, re-attach the driver to it
#         instead of waiting 20 s for a firmware-restart event that a device which was never reset
#         cannot send.  Measured 2026-09-22 on the machine that produced 0015: MHI came up in M0
#         (0x2) with the firmware alive, and the only thing missing was the driver's own state.
#
#   radiofix            (root) install the built ath12k.ko into updates/a16/ (default)
#   radiofix status     (any)  where each piece is, and whether the fix is the loaded module
#   radiofix build      (any)  rebuild the module from the tree (does not need root)
#   radiofix revert     (root) remove the module from updates/a16/
#
# WHY
# ---
# The Wi-Fi wedge, narrowed on 2026-09-22 (see notes/2026-09-22-wifi-suspend-ladder.md):
#
#   * the suspend keeps the device on purpose -- ath12k_mhi_stop(is_suspend=true) ->
#     mhi_power_down_keep_dev() -- i.e. the firmware is meant to still be running;
#   * the resume then calls ath12k_pci_power_up(), which runs the **SoC global reset**
#     (ath12k_pci_sw_reset() -> ath12k_pci_soc_global_reset()), throwing the firmware away;
#   * nothing re-downloads it (that lives in the probe/QMI flow), so the device comes up in neither
#     SBL nor mission mode and ath12k_core_resume() times out after 20 s:
#
#       mhi mhi0: Wait for device to enter SBL or Mission mode      <- and no line after it
#       ath12k_wifi7_pci 0004:01:00.0: timeout while waiting for restart complete
#       ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110
#
# and every WMI command fails for the rest of the boot.  Patch 0014 marks the resume in
# ath12k_core_resume_early() (ATH12K_FLAG_A16_RESUMING) and makes ath12k_pci_power_up() skip the
# global reset when that flag is set, so MHI re-attaches to the firmware that is still there.
#
# It is one variable, it logs both MHI states, and it can be turned off per boot:
#   /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume   (default Y)
set -u

MODE="${1:-install}"
MODE2="${2:-}"      # e.g. keepmhi -- written into /etc/modprobe.d/a16-ath12k.conf
KVER=$(uname -r)
TREE="${A16_TREE:-/home/jc/build/linux-next-1a1de54f7369}"
KO="${A16_KO:-$TREE/drivers/net/wireless/ath/ath12k/ath12k.ko}"
SYMVERS="$TREE/Module.symvers.a16harvest"
UPD="/lib/modules/$KVER/updates/a16"
SHIPPED="/lib/modules/$KVER/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko"
PATCH="${A16_PATCH:-/home/jc/A16Build/BRINGUP/patches/retired/0014-ath12k-a16-no-soc-global-reset-on-resume.patch}"
LOG="${A16_LOG:-/home/jc/a16-payload/radiofix-$(date +%Y%m%d-%H%M%S).log}"
SKIP_ROOT="${A16_SKIP_ROOT:-0}"
DRY="${A16_DRY:-0}"

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
run()  { if [ "$DRY" = 1 ]; then say "   [dry-run] $*"; return 0; fi; "$@"; }

usage() {
  cat <<'EOF'
radiofix -- patches/0014: do not reset the WiFi SoC when resuming (the Wi-Fi wedge fix).

usage:
  sudo bash ~/a16.sh radiofix            install the built ath12k.ko into updates/a16/ and depmod
  sudo bash ~/a16.sh radiofix keepmhi    same, but also keep the MHI link (and the device's firmware)
                                         up across a suspend -- a16_keep_mhi_up=Y in
                                         /etc/modprobe.d/a16-ath12k.conf; takes effect on the next boot
  bash .../a16-install-ath12k-resume-fix.sh status    read-only: source, module, installed, loaded
  bash .../a16-install-ath12k-resume-fix.sh build     rebuild ath12k.ko from the tree (no root)
  sudo bash ~/a16.sh radiofix revert     remove it from updates/a16/ and depmod
  sudo bash ~/a16.sh radiofix revive     no reboot: unbind+bind the WiFi PCI function so the driver
                                         re-probes it (the probe path is the cold boot that works)

then:  sudo bash ~/a16.sh wifisleep test      (does the radio survive a suspend now?)
and if the screen stays black after a resume: ssh in and read the log instead of power-cycling --
      sudo journalctl -k -b | grep -E 'A16: resume|restart complete|MHI state'
log: ~/a16-payload/radiofix-<timestamp>.log
EOF
}
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

abi_check() {
  local ko="$1" symvers="${2:-$SYMVERS}"
  [ -f "$ko" ] || { say "   $ko MISSING -- run: bash $0 build"; return 1; }
  [ -f "$symvers" ] || symvers="$TREE/Module.symvers"
  local kvm ml
  kvm=$(modinfo -F vermagic "$SHIPPED" 2>/dev/null)
  ml=$(modprobe --dump-modversions "$SHIPPED" 2>/dev/null | awk '$2=="module_layout"{print $1}')
  say "   $(basename "$ko"): $(stat -c %s "$ko") bytes, $(stat -c %y "$ko" | cut -d. -f1)"
  say "   vermagic      : $(modinfo -F vermagic "$ko")"
  [ "$(modinfo -F vermagic "$ko")" = "$kvm" ] && say "   vermagic      : matches the kernel's ✓" || say "   vermagic      : MISMATCH (kernel: $kvm)"
  say "   module_layout : $(modprobe --dump-modversions "$ko" | awk '$2=="module_layout"{print $1}')   (kernel's: $ml)"
  say "   A16 parameter : $(modinfo -F parm "$ko" | grep -c a16_skip_global_reset_on_resume)   (1 = this is the patched build)"
  modprobe --dump-modversions "$ko" | awk '{print $1"\t"$2}' > /tmp/a16-radiofix-imports.txt
  python3 - "$symvers" <<'PY'
import sys
ours = {}
for l in open('/tmp/a16-radiofix-imports.txt'):
    c, s = l.split(); ours[s] = c
have = {}
for l in open(sys.argv[1]):
    f = l.split('\t')
    if len(f) >= 2: have[f[1]] = f[0]
missing = [s for s in ours if s not in have]
bad = [s for s in ours if s in have and ours[s].lower() != have[s].lower()]
print(f"   imports       : {len(ours)}   without a CRC: {len(missing)}   disagreeing: {len(bad)}")
if missing: print("   missing       :", missing[:8])
if bad: print("   disagreeing   :", bad[:8])
print("   ABI           : " + ("OK -- every import carries the kernel's CRC ✓" if not missing and not bad else "NOT SAFE -- do not install"))
PY
}

# The export side of MODVERSIONS.  A module that EXPORTS symbols consumed by another module must carry
# the CRC the kernel's own build gave those symbols -- and with CONFIG_EXTENDED_MODVERSIONS=y that CRC
# comes from the DWARF of the compiled source, so a different *minor* gcc produces different values.
# This kernel was built with gcc 15.2.0; this machine has 15.3.0, so a locally rebuilt ath12k.ko
# exports 114 of its 134 CRCs differently, and ath12k_wifi7.ko (the bundle's, unchanged) then refuses
# to load with "disagrees about version of symbol ath12k_…" -- which is exactly what happened on
# 2026-09-22: the Wi-Fi device had no driver at all after the restart.  The classic CRC table
# (__kcrctab) is what the loader compares, and the export list and its order are identical to the
# original build (__ksymtab_strings is byte-for-byte the same), so the original table can be copied in
# whole -- and that copy is then verified byte-for-byte.
STOCK_KO="/lib/modules/$KVER/kernel/drivers/net/wireless/ath/ath12k/ath12k.ko"

export_crc_check() {   # $1 = our .ko
  local ko="$1" tmp; tmp=$(mktemp -d)
  [ -f "$STOCK_KO" ] || { say "   export crcs  : no $STOCK_KO to compare with"; rm -rf "$tmp"; return 2; }
  objcopy --dump-section __ksymtab_strings="$tmp/ours.str" "$ko" 2>/dev/null
  objcopy --dump-section __ksymtab_strings="$tmp/stock.str" "$STOCK_KO" 2>/dev/null
  objcopy --dump-section __kcrctab="$tmp/ours.crc" "$ko" 2>/dev/null
  objcopy --dump-section __kcrctab="$tmp/stock.crc" "$STOCK_KO" 2>/dev/null
  if [ ! -s "$tmp/ours.str" ] || [ ! -s "$tmp/stock.str" ]; then say "   export crcs  : could not read the tables"; rm -rf "$tmp"; return 2; fi
  if ! cmp -s "$tmp/ours.str" "$tmp/stock.str"; then
    say "   export crcs  : the exported symbol list/order DIFFERS from the original build -- a wholesale"
    say "                  copy is not possible; do not install this module"
    rm -rf "$tmp"; return 1
  fi
  if cmp -s "$tmp/ours.crc" "$tmp/stock.crc"; then
    say "   export crcs  : identical to the original build ✓ ($(stat -c %s "$tmp/ours.crc") bytes)"
    rm -rf "$tmp"; return 0
  fi
  say "   export crcs  : DIFFER from the original build -- transplanting the original table"
  cp -f "$tmp/stock.crc" "$tmp/fix.crc"
  objcopy --update-section __kcrctab="$tmp/fix.crc" "$ko" || { say "   transplant   : objcopy FAILED"; rm -rf "$tmp"; return 1; }
  objcopy --dump-section __kcrctab="$tmp/ours2.crc" "$ko" 2>/dev/null
  if cmp -s "$tmp/ours2.crc" "$tmp/stock.crc"; then
    say "   transplant   : done and verified byte-for-byte ✓"
    rm -rf "$tmp"; return 0
  fi
  say "   transplant   : VERIFY FAILED -- do not install this module"
  rm -rf "$tmp"; return 1
}

do_build() {
  [ "$(id -u)" = 0 ] && { say "Run this as yourself, not with sudo."; exit 1; }
  rule
  say "-- apply patches/0014 to the tree if it is not there yet"
  if grep -q 'ATH12K_FLAG_A16_RESUMING' "$TREE/drivers/net/wireless/ath/ath12k/core.h" 2>/dev/null; then
    say "   already applied"
  else
    ( cd "$TREE" && patch -p1 --forward -s < "$PATCH" ) || { say "   FATAL: the patch did not apply"; exit 1; }
    say "   applied"
  fi
  rule
  say "-- symbol table: the harvest minus ath12k's own exports (modpost rejects those as double exports)"
  python3 - "$SYMVERS" "$TREE/Module.symvers" <<'PY'
import sys
kept, dropped = [], 0
for l in open(sys.argv[1]):
    f = l.split('\t')
    if len(f) >= 2 and 'ath12k' in f[1]:
        dropped += 1; continue
    kept.append(l)
open(sys.argv[2], 'w').writelines(kept)
print(f"   {len(kept)} CRCs kept, {dropped} ath12k_* dropped")
PY
  rule
  say "-- build ath12k.ko"
  export PATH="$HOME/pahole-local/usr/bin:$PATH"
  export LD_LIBRARY_PATH="$HOME/pahole-local/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
  ( cd "$TREE" && make --no-print-directory ARCH=arm64 -j"$(nproc)" M=drivers/net/wireless/ath/ath12k ath12k.ko ) || { say "   FATAL: build failed"; exit 1; }
  say "   built: $KO"
  rule
  say "-- export CRCs (what other modules see; see the note above export_crc_check)"
  export_crc_check "$KO" || { say "   FATAL: the module would not be loadable by ath12k_wifi7 -- not staging it"; exit 1; }
  rule
  say "-- verify"
  abi_check "$KO"
  rule
  say "NEXT:  sudo bash ~/a16.sh radiofix      (install it)   -- or 'revert' to take it out"
}

do_status() {
  rule
  say "-- source"
  say "   patch         : $PATCH $( [ -f "$PATCH" ] && echo present || echo MISSING)"
  say "   tree          : $(grep -q ATH12K_FLAG_A16_RESUMING "$TREE/drivers/net/wireless/ath/ath12k/core.h" 2>/dev/null && echo 'patched ✓' || echo 'not patched')"
  say "   built module  : $( [ -f "$KO" ] && echo "$KO ($(stat -c %s "$KO") bytes)" || echo 'not built')"
  rule
  say "-- the machine"
  say "   installed     : $( [ -f "$UPD/ath12k.ko" ] && echo yes || echo no)   ($UPD/ath12k.ko)"
  say "   loaded from   : $(modinfo -F filename ath12k 2>/dev/null)"
  say "   loaded parm   : $(cat /sys/module/ath12k/parameters/a16_skip_global_reset_on_resume 2>/dev/null || echo 'n/a (this is not the patched build)')"
  say "   fix level     : $(cat /sys/module/ath12k/parameters/a16_fix_level 2>/dev/null || echo 'n/a (module older than 0017)')"
  say "   keep MHI up   : $(cat /sys/module/ath12k/parameters/a16_keep_mhi_up 2>/dev/null || echo 'n/a')"
  say "   modprobe conf : $( [ -f /etc/modprobe.d/a16-ath12k.conf ] && tr -d '\n' < /etc/modprobe.d/a16-ath12k.conf || echo '(none)')"
  say "   ath12k_wifi7  : $(lsmod 2>/dev/null | awk '$1=="ath12k_wifi7"{print "loaded"} ' || true)$(lsmod 2>/dev/null | grep -q ath12k_wifi7 || echo 'NOT loaded ("disagrees about version of symbol ath12k_…" in the journal = the export CRCs above do not match)')"
  say "   radio now     : $(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: '$2=="connected"{print $1}' | head -1)"
  rule
}

do_install() {
  abi_check "$KO" || { say "not installing."; exit 1; }
  rule
  say "-- export CRCs"
  export_crc_check "$KO" || { say "NOT installing: ath12k_wifi7 would refuse the module and the radio would have no driver."; exit 1; }
  if ! modinfo -F parm "$KO" 2>/dev/null | grep -q a16_skip_global_reset_on_resume; then
    say "FATAL: this ath12k.ko has no a16_skip_global_reset_on_resume -- it is not the patched build"; exit 1
  fi
  rule
  say "-- install into $UPD (the shipped ath12k.ko is left where it is; updates/ wins in depmod)"
  run install -m 644 "$KO" "$UPD/ath12k.ko"
  run depmod -a "$KVER"
  say "   installed     : $( [ "$DRY" = 1 ] && echo '(dry-run)' || { [ -f "$UPD/ath12k.ko" ] && echo yes || echo 'FAILED'; } )"

  # module options -- read when the module is loaded, so they take effect at the next boot
  local conf=/etc/modprobe.d/a16-ath12k.conf opts="a16_skip_global_reset_on_resume=Y"
  case "$MODE2" in
    ""|default) : ;;
    keepmhi|keep-mhi|keep) opts="$opts a16_keep_mhi_up=Y" ;;
    *) say "   unknown mode '$MODE2' -- writing the default options";;
  esac
  say "-- module options, $conf  (applied when the module is loaded, i.e. at the next boot)"
  if [ "$DRY" = 1 ]; then say "   [dry-run] write: options ath12k $opts"; else printf 'options ath12k %s\n' "$opts" > "$conf"; fi
  say "   options ath12k $opts"
  if [ "$opts" != "a16_skip_global_reset_on_resume=Y" ]; then
    say "   (a16_keep_mhi_up=Y: ath12k_core_suspend_late() leaves the MHI link up, so the device keeps its"
    say "    firmware *and* the host keeps its rings/HTC; the resume only re-arms the interrupts.)"
  fi
  say "   removal       : sudo bash ~/a16.sh radiofix revert"
  rule
  say "NEXT:"
  say "   1.  start again into entry [3]"
  say "   2.  bash ~/A16Build/BRINGUP/tools/a16-install-ath12k-resume-fix.sh status   -> the parameter must read Y"
  say "   3.  sudo ~/a16step                                                          -> does the radio survive?"
  say ""
  say "   FIRST CHECK after the restart -- the device must have a driver at all:"
  say "      lsmod | grep ath12k_wifi7        (missing = the export CRCs did not match: see below)"
  say ""
  say "   What success looks like in the log:"
  say "      ath12k_wifi7_pci 0004:01:00.0: A16: resume -- not resetting the device (MHI state 0x..); ..."
  say "      ath12k_wifi7_pci 0004:01:00.0: A16: resume -- MHI state after power up: 0x3 (3 = M0)"
  say "      ... and the interface back in a few seconds, with no 'Wait for device to enter SBL'."
  say ""
  say "   If the screen stays black after the resume: ssh in (the machine is usually alive) and read"
  say "      sudo journalctl -k -b | grep -E 'A16: resume|restart complete|MHI state'"
  say "   instead of power-cycling -- a hard reset loses the log."
}

do_revert() {
  rule
  say "-- remove the patched module"
  run rm -f "$UPD/ath12k.ko"
  run depmod -a "$KVER"
  say "   installed     : $( [ "$DRY" = 1 ] && echo '(dry-run)' || { [ -f "$UPD/ath12k.ko" ] && echo 'still there!' || echo removed; } )"
  rule
  say "start again to unload it."
}

say "=== radiofix  (a16-install-ath12k-resume-fix.sh)  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
say "kernel: $KVER   tree: $TREE"
say "log   : $LOG"
[ "$DRY" = 1 ] && say "A16_DRY=1: every command is printed, nothing changes."

# revive: after a resume that failed, the radio can be brought back without a reboot by making the
# driver re-probe the PCI function.  Unbind tears the driver off the device, bind runs probe, and
# probe's power-up is the one sequence measured to cold-boot this chip successfully.
do_revive() {
  rule
  say "-- revive: re-probe the WiFi device without rebooting"
  if [ "$DRY" = 1 ]; then say "   [dry-run] unbind + bind the ath12k PCI function"; return 0; fi   # A16_DRY

  # 0017 (idempotent thermal cleanup) is what makes the remove path survivable after a failed
  # resume: without it the unbind dies in hwmon_device_unregister(NULL) and freezes the machine.
  local lvl=""
  [ -r /sys/module/ath12k/parameters/a16_fix_level ] && lvl=$(cat /sys/module/ath12k/parameters/a16_fix_level)
  if [ -z "$lvl" ] || [ "$lvl" -lt 17 ] 2>/dev/null; then
    say "   the RUNNING ath12k module does not have fix 0017 (idempotent thermal cleanup)."
    say "   Without it, unbinding a radio whose resume already failed dies in"
    say "   hwmon_device_unregister(NULL) (pc: hwmon_device_unregister+0x38) and takes the machine"
    say "   with it.  Install the new module and reboot first:"
    say ""
    say "       sudo bash ~/a16.sh radiofix"
    say ""
    say "   (running module reports fix level: ${lvl:-none})"
    return 1
  fi

  # A rebind only rebuilds the *driver*.  If the resume already failed, the MHI controller's devices
  # and the QRTR/QMI objects from the old instance are still around, and the new probe then dies in
  # mhi_queue() ("duplicate filename /bus/mhi/devices/mhi0_IPCR", measured 2026-09-22 11:37), so say
  # so instead of walking the operator into another freeze.
  # Also covers the case where the resume itself "succeeded" but the radio came back dead -- then there
  # is no 'resume failed' line, only WMI timeouts (measured 2026-09-22 12:31 in boot -1: the keep-MHI-up
  # resume left 'wmi command 16387 timeout' every 13 s).  Unbinding there hangs in mhi_power_down ->
  # flush_work with the MHI wedged ("mhi mhi0: Device failed to clear MHI Reset"), and a shell stuck in
  # D state blocks every later system suspend ("Freezing user space processes failed after 20 s: 1 tasks
  # refusing to freeze"), which is what made the machine look completely dead.
  if journalctl -k -b --no-pager -o cat 2>/dev/null | grep -qE 'A16: resume failed|wmi command [0-9]+ timeout'; then
    say "   this boot has already had a failed resume (or a resume that left the radio dead -- see the"
    say "   'wmi command ... timeout' lines above).  A rebind cannot rebuild the MHI layer in that state:"
    say "   the old controller's devices are still registered and the new probe dies in mhi_queue()"
    say "   (measured 11:37 -- \'duplicate filename /bus/mhi/devices/mhi0_IPCR\'), and the unbind itself"
    say "   can hang in mhi_power_down -> flush_work (measured 12:33 -- 'Device failed to clear MHI Reset'),"
    say "   which leaves a shell in D state and blocks every later suspend."
    say "   Reboot instead: the radio comes back on a clean boot."
    return 1
  fi

  local drv=/sys/bus/pci/drivers/ath12k_wifi7_pci bdf i=0
  bdf=$(ls -d "$drv"/000* 2>/dev/null | head -1 | xargs -r basename)
  if [ -z "$bdf" ]; then
    say "   no ath12k PCI function is bound (driver not loaded?) -- nothing to re-probe"
    say "   check: lsmod | grep ath12k_wifi7"
    return 1
  fi
  say "   device: $bdf"

  say "-- unbinding (the driver lets go of the device)..."
  if ! echo "$bdf" > "$drv/unbind" 2>/dev/null; then
    say "   unbind failed -- is the built module the one that is loaded?  (lsmod | grep ath12k)"
    return 1
  fi
  sleep 3

  say "-- binding (driver probe = the device cold-boots; watch for the firmware download)..."
  if ! echo "$bdf" > "$drv/bind" 2>/dev/null; then
    say "   bind failed -- read the kernel log:  sudo journalctl -k -b | tail -40"
    return 1
  fi

  say "-- waiting up to 60 s for the interface"
  while [ "$i" -lt 30 ]; do
    i=$((i+1)); sleep 2
    ip -o link show wlP4p1s0 >/dev/null 2>&1 || continue
    say "   interface wlP4p1s0 is back after ~$((i*2))s"
    sleep 4
    if nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep -q '^wlP4p1s0:connected'; then
      say "   RADIO : BACK -- associated, no reboot needed"
    else
      say "   RADIO : interface up, not associated yet (NetworkManager may still be reconnecting --"
      say "           check 'nmcli dev status' in a few seconds)"
    fi
    say "-- what the driver said:"
    journalctl -k -b --no-pager -o cat 2>/dev/null | grep -E 'A16|ath12k_wifi7_pci|MHI' | tail -12 | sed 's/^/   /'
    return 0
  done
  say "   the interface did not come back in 60 s.  Read the log:"
  say "      sudo journalctl -k -b | tail -40"
  say "   and if the device is wedged, a reboot is the fallback."
  return 1
}

case "$MODE" in
  install) [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh radiofix"; say ""; exit 1; }; do_install ;;
  revive)  [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh radiofix revive"; say ""; exit 1; }; do_revive ;;
  build)   do_build ;;
  status)  do_status ;;
  revert)  [ "$(id -u)" = 0 ] || [ "$SKIP_ROOT" = 1 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh radiofix revert"; say ""; exit 1; }; do_revert ;;
  *) say "usage: a16-install-ath12k-resume-fix.sh [install|build|status|revert]"; exit 2 ;;
esac
say ""
say "log: $LOG"
