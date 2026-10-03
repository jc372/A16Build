#!/usr/bin/env bash
# a16-install-tplg.sh -- give the audio card its missing topology file.
#
#     sudo bash /home/jc/a16-payload/a16-install-tplg.sh
#     # or try the sibling ASUS laptop's topology instead:
#     sudo A16_TPLG_SRC=/lib/firmware/qcom/x1e80100/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst \
#          bash /home/jc/a16-payload/a16-install-tplg.sh
#
# Why: with the DSP firmware installed the ADSP and CDSP now come up
# (remoteproc1/2 = running, PDR audio_pd up, GPR service registered), and the card
# then fails one step later, on one file the kernel asks for by machine name:
#     qcom-apm gprsvc:service:2:1: Direct firmware load for
#         qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin failed with error -2
#     snd-x1e80100 sound: ASoC: failed to instantiate card -2
# The kernel tree builds that topology per machine; linux-firmware ships one for
# the glymur reference board (qcom/glymur/GLYMUR-CRD-tplg.bin.zst) and one for a
# sibling ASUS laptop (x1e80100/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst).  Neither
# is this chassis, so this installs the SoC-matching one under the requested name
# as a TEST: if the card appears, the remaining difference is audio routing.
# Removal:  sudo rm /lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin.zst
set -u

REQUESTED_NAME="GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin"
DESTDIR="${A16_TPLG_DIR:-/lib/firmware/qcom/glymur}"
SRC="${A16_TPLG_SRC:-$DESTDIR/GLYMUR-CRD-tplg.bin.zst}"
ESP="${A16_ESP:-/boot/efi}"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
if touch "$ESP/.a16t" 2>/dev/null; then rm -f "$ESP/.a16t"; LOG="$ESP/A16TPLG-$STAMP.log"; else LOG="/var/tmp/A16TPLG-$STAMP.log"; fi
: > "$LOG"
log() { printf '[a16-tplg] %s\n' "$*" | tee -a "$LOG"; }
# $1 is a label for the log; the rest is the command.  The shift matters: without it
# the helper tries to execute the label itself (exit 127) while the caller still
# prints its own success line.
run() { local label="${1:-cmd}"; shift; local out st; out="$("$@" 2>&1)"; st=$?; { echo "### [$label] \$ $*"; printf '%s\n' "$out"; echo "### exit: $st"; } | tee -a "$LOG"; return $st; }

if [ "$(id -u)" != "0" ] && [ "${A16_ALLOW_NONROOT:-0}" != "1" ]; then echo "[a16-tplg] needs root: sudo bash $0"; exit 1; fi
log "=== a16-install-tplg $STAMP (kernel $(uname -r)) ==="
log "source: $SRC"
log "target: $DESTDIR/$REQUESTED_NAME.zst"

[ -f "$SRC" ] || { log "source topology missing -- aborting"; log "available:"; ls -1 /lib/firmware/qcom/glymur/ /lib/firmware/qcom/x1e80100/ 2>/dev/null | grep -i tplg | sed 's/^/[a16-tplg]   /' | tee -a "$LOG"; exit 1; }
log "source sha256: $(sha256sum "$SRC" | cut -d' ' -f1)"

# the firmware loader tries <name> then <name>.zst, so install it compressed
run "install-tplg" install -m 0644 "$SRC" "$DESTDIR/$REQUESTED_NAME.zst" || { log "install failed"; exit 1; }
run "ls" ls -la "$DESTDIR/$REQUESTED_NAME.zst"

# reload the machine driver so the card is built again, now with the topology
log "=== reload snd_soc_x1e80100 ==="
run "rmmod" modprobe -r snd_soc_x1e80100
sleep 1
run "modprobe" modprobe snd_soc_x1e80100
sleep 4
run "cards" cat /proc/asound/cards
log "=== log ==="
journalctl -k -b --no-pager 2>/dev/null | grep -iE 'qcom-apm|gprsvc|tplg|snd-x1e80100|soundwire|ASoC|card' | tail -25 | sed 's/^/[a16-tplg]   /' | tee -a "$LOG"

log "=== summary ==="
if [ -s /proc/asound/cards ] && grep -qE '^[[:space:]]*[0-9]+' /proc/asound/cards; then
  log "A SOUND CARD EXISTS NOW: $(grep -v '^---' /proc/asound/cards | head -3 | tr '\n' ' ')"
  log "check it from your session: wpctl status | pactl list short sinks"
else
  log "still no card in this boot.  Read the log above for the new failure:"
  log "  'tplg ... failed' again  -> try A16_TPLG_SRC=/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst"
  log "  any other ASoC error     -> that is the next blocker, send me this log"
  log "  nothing new at all       -> reboot once: the card is built early in boot and a"
  log "                              live reload cannot always replay the codec/DSP handshake"
fi
log "remove the test file with: rm $DESTDIR/$REQUESTED_NAME.zst"
log "=== done ==="
sync
cp -f "$LOG" "/home/jc/a16-payload/$(basename "$LOG")" 2>/dev/null && chown --reference=/home/jc/a16-payload "/home/jc/a16-payload/$(basename "$LOG")" 2>/dev/null
echo "[a16-tplg] log: $LOG"
exit 0
