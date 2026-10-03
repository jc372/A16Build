#!/usr/bin/env bash
# steps/40-wifi.sh -- serve this machine's own board data to ath12k, then check the radio is up.
#
#   sudo bash steps/40-wifi.sh              # install + verify + a quick association check
#   sudo bash steps/40-wifi.sh --verify     # verify only (the board data is already installed)
#
# Why: ath12k bound the QCC2072 and loaded firmware, but every attempt failed with
# "failed to fetch board data" because the shipped board-2.bin has no entry for this machine's
# BDF key.  The fix is to wrap the machine's own vendor image under that key -- the committed
# container at firmware/ath12k-board-2-qcc2072-e14f/ (526,972 B, sha256 314e2d57…) reproduces
# from tools/make-a16-qcc2072-board-2.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRINGUP="$(dirname "$HERE")"; TOOLS="$BRINGUP/tools"
REPO="$(dirname "$BRINGUP")"
MODE="${1:-install}"
LOG="${A16_LOG:-$HOME/a16-payload/A16STEP40-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== step 40: Wi-Fi board data $(date +%Y%m%d-%H%M%S) ==="

ART="$REPO/firmware/ath12k-board-2-qcc2072-e14f/board-2.bin"
if [ -f "$ART" ]; then
  say "   committed container: $ART ($(stat -c %s "$ART") bytes, sha256 $(sha256sum "$ART" | cut -c1-16)…)"
else
  say "   no committed container -- tools/make-a16-qcc2072-board-2.sh can rebuild it (needs the"
  say "   Windows vendor image bdwlan_qcc2072_1p0_ncm820A.elf from the firmware tree)"
fi

case "$MODE" in
  --verify)
    say "   verify-only run"
    [ "$(id -u)" = 0 ] && bash "$TOOLS/a16-wifi-bdf-test.sh" --verify 2>&1 | sed 's/^/   /' | tee -a "$LOG" \
                       || say "   (--verify wants root for the /lib/firmware check)"
    ;;
  *)
    [ "$(id -u)" = 0 ] || { say "   needs root: sudo bash $0"; exit 1; }
    say "   running tools/a16-wifi-bdf-test.sh (install + verify) …"
    bash "$TOOLS/a16-wifi-bdf-test.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
    ;;
esac

say ""
say "   radio state:"
if ls /sys/class/net/wl* >/dev/null 2>&1; then
  for d in /sys/class/net/wl*; do say "     $(basename "$d"): $(cat "$d/operstate" 2>/dev/null)"; done
  say "     association: $(iw dev 2>/dev/null | grep -m1 SSID || echo 'not associated')"
  say "     signal     : $(iw dev 2>/dev/null | grep -m1 signal || echo '-')"
  say "     board data : $(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c 'failed to fetch board data') failure line(s) this boot (want 0)"
else
  say "     no /sys/class/net/wl* interface -- check dmesg for ath12k probe errors"
fi
say ""
say "   Optional profile tuning (BSSID/band preference, powersave, route):"
say "     sudo bash $TOOLS/a16-wifi-tune.sh"
say "   NEXT: sudo bash steps/50-bluetooth.sh"
say "log: $LOG"
