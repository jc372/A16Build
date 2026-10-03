#!/usr/bin/env bash
# steps/30-firmware.sh -- put the machine's own firmware where the kernel looks for it: the four
#                         DSP blobs (ADSP/CDSP) and the Bluetooth files btqca asks for.
#
#   sudo bash steps/30-firmware.sh
#
# Everything installed here comes from the committed Windows extraction
# (firmware/windows-driverstore-2026-09-16/), which is why this step needs no downloads.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRINGUP="$(dirname "$HERE")"; TOOLS="$BRINGUP/tools"
REPO="$(dirname "$BRINGUP")"
LOG="${A16_LOG:-$HOME/a16-payload/A16STEP30-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== step 30: firmware $(date +%Y%m%d-%H%M%S) ==="
[ "$(id -u)" = 0 ] || { say "   needs root: sudo bash $0"; exit 1; }
FW="$REPO/firmware/windows-driverstore-2026-09-16"
[ -d "$FW" ] || { say "   FATAL: $FW missing -- git pull the repo first"; exit 1; }
say "   source: $FW ($(find "$FW" -type f | wc -l) files, $(du -sh "$FW" | cut -f1))"

say "   DSP blobs (qcom/glymur/ASUSTeK/UX3607OA) …"
bash "$TOOLS/a16-install-firmware.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
for f in qcadsp8480.mbn qccdsp8480.mbn adsp_dtbs.elf cdsp_dtbs.elf; do
  p="/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/$f"
  [ -f "$p" ] && say "     ok   $f ($(stat -c %s "$p") bytes)" || say "     FAIL $f missing"
done

say "   Bluetooth blobs (btqca's names, /lib/firmware/qca) …"
bash "$TOOLS/a16-bt-setup.sh" install 2>&1 | sed 's/^/   /' | tee -a "$LOG"
for f in hmtbtfw20.tlv hmtbtfw20.ver hmtnv20.b105 hmtnv20.b10f hmtnv20.b112 hmtnv20.b3b clnbtfw10.tlv clnbtnv10.b03 clnbtnv10.b17 bsrc_bt.bin; do
  p="/lib/firmware/qca/$f"
  [ -f "$p" ] && say "     ok   $f ($(stat -c %s "$p") bytes)" || say "     MISSING $f"
done

say "   DSP state now: $(for r in /sys/class/remoteproc/remoteproc*/; do printf '%s=%s ' "$(basename "$r")" "$(cat "$r/state" 2>/dev/null)"; done)"
say ""
say "   Note: the Bluetooth patch file the driver asks for on this part is NOT in this set --"
say "   see NEXT-STEPS.md item 6 (it asks for qca/hmtbtfw11.tlv; the chip works without it)."
say "   NEXT: sudo bash steps/40-wifi.sh"
say "log: $LOG"
