#!/usr/bin/env bash
# a16-suspend-drain.sh -- measure what a suspend actually costs, in Wh and % of the pack.
#
#   mark    record battery energy + clock, just before you close the lid
#   report  read it back after resuming and print the drain
#   deep    switch to suspend-to-RAM  (root; this is the experiment)
#   s2idle  switch back to the current mode (root)
#   state   show the sleep mode and the last measurement
#
# Why: "30% overnight" is a rate, and a rate needs two numbers. The gap between
# CLOCK_BOOTTIME and CLOCK_MONOTONIC grows only while the machine is suspended, so
# the difference in that gap between mark and report is the time genuinely asleep --
# independent of whether the screen, fans or keyboard did anything.
set -u
BAT=/sys/class/power_supply/qcom-battmgr-bat
STATE_DIR=${A16_PAYLOAD:-$HOME/a16-payload}
STATE=$STATE_DIR/suspend-drain.state
FULL_WH=66.6          # energy_full of this pack, from the battery itself
mkdir -p "$STATE_DIR"

energy() { cat "$BAT/energy_now" 2>/dev/null; }
gap()    { python3 -c "import time;print(round(time.clock_gettime(time.CLOCK_BOOTTIME)-time.clock_gettime(time.CLOCK_MONOTONIC),1))"; }
mode()   { sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null; }

case "${1:-state}" in
mark)
  e=$(energy); [ -n "$e" ] || { echo "this battery exposes no energy_now"; exit 1; }
  { echo "energy_uwh=$e"
    echo "gap_at_mark=$(gap)"
    echo "wall_epoch=$(date +%s)"
    echo "wall_text='$(date '+%F %T %Z')'"
    echo "sleep_mode=$(mode)"; } > "$STATE"
  printf 'recorded  %.2f Wh  (%s)  mode=%s\n' "$(awk "BEGIN{printf \"%.3f\", $e/1e6}")" "$(date '+%H:%M:%S')" "$(mode)"
  printf 'now close the lid (or: sudo systemctl suspend), wait, then run:  report\n'
  ;;
report)
  [ -f "$STATE" ] || { echo "nothing recorded yet -- run 'mark' first"; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE"
  e=$(energy); [ -n "$e" ] || { echo "this battery exposes no energy_now"; exit 1; }
  now_gap=$(gap); now_epoch=$(date +%s)
  python3 - "$energy_uwh" "$e" "$gap_at_mark" "$now_gap" "$wall_epoch" "$now_epoch" "$FULL_WH" <<'PY'
import sys
e0, e1, g0, g1, t0, t1, full = (float(x) for x in sys.argv[1:8])
drained = (e0 - e1) / 1e6            # Wh
elapsed = (t1 - t0) / 3600.0         # h wall clock
asleep  = max(0.0, (g1 - g0)) / 3600.0   # h genuinely suspended
print(f"  drained   : {drained:.2f} Wh   ({drained/full*100:.1f}% of the {full:.0f} Wh pack)")
print(f"  wall time : {elapsed*60:.0f} min")
print(f"  asleep    : {asleep*60:.0f} min")
if drained <= 0:
    print("  (battery gained -- it was on charge)")
elif asleep < 0.05:
    print("  NOT SUSPENDED: the machine did not sleep at all, so this is awake drain.")
    print(f"  awake rate: {drained/elapsed:.2f} W")
else:
    print(f"  asleep rate: {drained/asleep:.2f} W")
    if elapsed > asleep * 1.15:
        print(f"  (awake for {(elapsed-asleep)*60:.0f} min of the wall time)")
    print()
    print("  reference: 2.4 W = 30% overnight, which is what s2idle costs on this machine.")
    print("  under ~0.8 W would mean the machine is reaching a real low-power state.")
PY
  ;;
deep|s2idle)
  [ "$(id -u)" = 0 ] || { echo "need root: sudo $0 $1"; exit 1; }
  echo "$1" > /sys/power/mem_sleep || { echo "could not write mem_sleep"; exit 1; }
  printf 'sleep mode now: %s\n' "$(mode)"
  printf 'test it:  mark; close the lid for ~20 min; report   -- and compare with the other mode\n'
  ;;
unbind|bind)
  # Unbinding the PCI function powers the Wi-Fi chip down while leaving the whole stack
  # loaded -- unlike 'modprobe -r ath12k', which fails with "in use" because ath12k_wifi7
  # sits on top of it. Reversible with the matching 'bind'.
  [ "$(id -u)" = 0 ] || { echo "need root: sudo $0 $1"; exit 1; }
  BDF=${A16_WIFI_BDF:-0004:01:00.0}
  DRV=/sys/bus/pci/drivers/ath12k_wifi7_pci
  [ -d "$DRV" ] || { echo "no $DRV -- is the Wi-Fi driver built as ath12k_wifi7_pci?"; exit 1; }
  dev=$(ls -d "$DRV"/0000* 2>/dev/null | head -1)
  dev=${dev:-$DRV/$BDF}
  case "$1" in
    unbind)
      [ -e "$dev" ] || { echo "$BDF is not bound to ath12k_wifi7_pci"; exit 1; }
      echo "$BDF" > "$DRV/unbind" || { echo "unbind failed"; exit 1; }
      sleep 2
      printf 'unbound %s from ath12k_wifi7_pci\n' "$BDF"
      printf '  wlan interfaces now: %s\n' "$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -c wifi) wifi device(s)"
      printf '  link power state  : %s\n' "$(cat /sys/bus/pci/devices/$BDF/power_state 2>/dev/null || echo n/a)"
      printf 're-bind with:  sudo %s bind\n' "$0"
      ;;
    bind)
      echo "$BDF" > "$DRV/bind" || { echo "bind failed"; exit 1; }
      sleep 5
      printf 'bound %s back to ath12k_wifi7_pci\n' "$BDF"
      printf '  wlan interfaces now: %s wifi device(s)\n' "$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -c wifi)"
      ;;
  esac
  ;;
state|*)
  printf '  sleep mode : %s   (%s)\n' "$(mode)" "$(cat /sys/power/mem_sleep 2>/dev/null)"
  printf '  energy now : %s Wh\n' "$(awk "BEGIN{printf \"%.2f\", $(energy || echo 0)/1e6}")"
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    printf '  last mark  : %s   %.2f Wh   gap %s\n' "$wall_text" \
      "$(awk "BEGIN{printf \"%.2f\", $energy_uwh/1e6}")" "$gap_at_mark"
  else
    printf '  last mark  : none\n'
  fi
  ;;
esac
