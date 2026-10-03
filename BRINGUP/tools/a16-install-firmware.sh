#!/usr/bin/env bash
# a16-install-firmware.sh -- install the four DSP firmware blobs the payload
# carries into /lib/firmware, then try to bring the ADSP/CDSP up live (no reboot
# needed if it works).
#
#     sudo bash /home/jc/a16-payload/a16-install-firmware.sh
#
# Why: on this machine the ADSP and CDSP remoteprocs are both `offline` because
# request_firmware() returns -2 for exactly these paths (seen verbatim in the
# kernel log):
#     remoteproc1 (adsp): qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn
#     remoteproc2 (cdsp): qcom/glymur/ASUSTeK/UX3607OA/qccdsp8480.mbn
# and the audio stack above them (snd_soc_x1e80100, soundwire_qcom, the WSA/VA
# LPASS macros, qcom_q6v5_pas) is loaded and waiting.  Without the DSPs there is
# no sound card at all, which the desktop shows as "dummy output".
#
# The payload ships these four files under a16-local-firmware/, with sha256
# entries in sha256sums.txt -- both are verified before anything is installed.
#
# Test mode (installs into a fake /lib/firmware, skips the live remoteproc start):
#     A16_ALLOW_NONROOT=1 A16_FWROOT=/tmp/fwtest bash a16-install-firmware.sh
set -u

STAGE_DIR="/home/jc/a16-payload"
SUMS="$STAGE_DIR/sha256sums.txt"
SRCROOT="$STAGE_DIR/a16-local-firmware"
FWROOT="${A16_FWROOT:-/lib/firmware}"
DEST="$FWROOT/qcom/glymur/ASUSTeK/UX3607OA"
ESP="${A16_ESP:-/boot/efi}"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"

if [ "$(id -u)" != "0" ] && [ "${A16_ALLOW_NONROOT:-0}" != "1" ]; then
  echo "[a16-fw] needs root. Re-run as:"; echo "    sudo bash $0"; exit 1
fi
if touch "$ESP/.a16w" 2>/dev/null; then rm -f "$ESP/.a16w"; LOG="$ESP/A16FIRMWARE.LOG"; else LOG="/var/tmp/A16FIRMWARE.LOG"; fi
: > "$LOG"
log() { printf '[a16-fw] %s\n' "$*" | tee -a "$LOG"; }
run() { local l="$1"; shift; local out st; out="$("$@" 2>&1)"; st=$?; { echo "### \$ $*"; printf '%s\n' "$out"; echo "### exit: $st"; } | tee -a "$LOG"; return $st; }

log "=== a16-install-firmware $STAMP (kernel $(uname -r)) ==="
log "src=$SRCROOT  dest=$DEST"
[ -d "$SRCROOT" ] || { log "payload firmware dir missing -- aborting"; exit 1; }
[ -f "$SUMS" ]    || { log "sha256sums.txt missing -- aborting"; exit 1; }

# ---- 1. verify every blob against the payload's own checksum list ----------
log "=== verify ==="
FAIL=0; NFILES=0
while IFS= read -r line; do
  sum="${line%% *}"; rel="${line##* }"
  case "$rel" in a16-local-firmware/*) ;; *) continue ;; esac
  NFILES=$((NFILES+1))
  if [ ! -f "$STAGE_DIR/$rel" ]; then log "MISSING  $rel"; FAIL=1; continue; fi
  got="$(sha256sum "$STAGE_DIR/$rel" | cut -d' ' -f1)"
  if [ "$got" = "$sum" ]; then log "OK       $rel"; else log "MISMATCH $rel (want $sum, got $got)"; FAIL=1; fi
done < "$SUMS"
log "blobs listed in sha256sums.txt: $NFILES"
[ "$FAIL" = 0 ] || { log "verification failed -- nothing installed"; exit 1; }

# ---- 2. install them where the kernel asks for them ------------------------
log "=== install into $DEST ==="
mkdir -p "$DEST" || { log "cannot create $DEST -- aborting"; exit 1; }
for f in "$SRCROOT"/qcom/glymur/ASUSTeK/UX3607OA/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  run "install-$b" install -m 0644 "$f" "$DEST/$b" || { log "install of $b failed"; exit 1; }
done
log "--- installed ---"
run "ls-dest" ls -la "$DEST"
for f in "$DEST"/*; do [ -f "$f" ] && log "  $(sha256sum "$f" | cut -c1-16)...  $f"; done

# ---- 3. try to bring the DSPs up now, no reboot ---------------------------
log "=== remoteproc ==="
for r in /sys/class/remoteproc/remoteproc*; do
  [ -e "$r/state" ] || continue
  n="$(cat "$r/name" 2>/dev/null)"; st="$(cat "$r/state" 2>/dev/null)"; fw="$(cat "$r/firmware" 2>/dev/null)"
  log "$(basename "$r"): name=$n state=$st firmware=$fw"
  if [ "$st" = "offline" ]; then
    if [ "${A16_ALLOW_NONROOT:-0}" = "1" ]; then
      log "  (test mode: not starting $n)"
    else
      log "  state -> start"
      run "start-$n" bash -c "echo start > '$r/state'"
      log "  state now: $(cat "$r/state" 2>/dev/null)"
    fi
  fi
done

# ---- 4. what the audio stack says now ------------------------------------
log "=== audio ==="
run "asound" bash -c 'cat /proc/asound/cards 2>/dev/null'
run "sound-modules" bash -c 'lsmod | grep -iE "snd|soundwire|lpass" | head -15'
if [ "${A16_ALLOW_NONROOT:-0}" != "1" ]; then
  log "--- kernel log, last 25 lines mentioning the DSP/audio ---"
  journalctl -k -b --no-pager 2>/dev/null | grep -iE 'remoteproc|adsp|cdsp|soundwire|snd_soc|asoc|q6v5' | tail -25 | sed 's/^/[a16-fw]   /' | tee -a "$LOG"
fi

# ---- 5. summary ----------------------------------------------------------
log "=== summary ==="
log "installed: $(ls -1 "$DEST" 2>/dev/null | tr '\n' ' ')"
log "next: if /proc/asound/cards still shows no card, reboot once -- the codec/machine"
log "      drivers probe in a fixed order and may need the DSP to appear first."
log "      then check: journalctl -k -b | grep -iE 'remoteproc|soundwire|snd_soc'"
log "not covered here (platform gaps, not local configuration):"
log "  * wi-fi: ath12k needs a board-data entry for THIS module; the installed"
log "      ath12k/QCC2072/hw1.0/board-2.bin carries only"
log "      subsystem-device e15a (board-id 24) and 17cb/1110 (12/19/24), while the"
log "      card reports subsystem-device e14f / board-id 255 -- so no match, and"
log "      it fails the same way under ACPI (nothing to do with the DT boot)."
log "  * bluetooth: the machine DTS declares no BT node at all (only the wcn"
log "      pinctrl states and rails) and ACPI's \\_SB_.BTH0 / QCOM0F6B has no"
log "      driver in either kernel -- upstream work, not a setting."
log "=== done ==="
[ "$LOG" != "$STAGE_DIR/A16FIRMWARE.LOG" ] && { cp -f "$LOG" "$STAGE_DIR/A16FIRMWARE.LOG" 2>/dev/null; chown --reference="$STAGE_DIR" "$STAGE_DIR/A16FIRMWARE.LOG" 2>/dev/null; }
echo "[a16-fw] log: $LOG"
exit 0
