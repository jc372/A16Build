#!/bin/bash
# Why the internal speakers are silent, and the fix.
#
# The audio DSP never boots.  It asks for its firmware while the initramfs is
# still the root, and the firmware lives on the real root, which is not mounted
# yet.  The log says exactly that, about a hundred lines before the root appears:
#
#   line 592  Run /init as init process
#   line 688  remoteproc remoteproc1: Direct firmware load for
#             qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn failed with error -2
#   line 691  remoteproc remoteproc1: request_firmware failed: -2
#   line 911  EXT4-fs (nvme0n1p17): mounted filesystem f8e005e9-...
#
# With no ADSP there is no SoundWire codec and no sound card at all --
# /proc/asound/cards reports "--- no soundcards ---".  Bluetooth still works
# because it does not go through the ADSP, which is why earbuds are fine and the
# speakers are not.
#
# The kernel did not change.  The same t2 kernel had sound on the overnight boot
# and lost it on the boot after the initramfs was rebuilt at 08:02:
#
#   boot -7   t2   line 732  Booting fw image ...qcadsp8480.mbn, size 19867608
#   boot -6   t2   line 688  Direct firmware load ... failed with error -2
#
# and the initrd sizes say the same thing:
#
#   the one that worked   48,432,089   10-04 21:27   (kept in ec-test-backup-...)
#   the one in /boot     75,175,505   10-05 08:02
#
# Usage:
#   sudo bash a16-audio-adsp-initramfs.sh status    what is in each initrd
#   sudo bash a16-audio-adsp-initramfs.sh fix       put the firmware in, regenerate
#   sudo bash a16-audio-adsp-initramfs.sh revert    take the hook back out
#
# status changes nothing.  fix keeps a copy of the initrd it replaces, and revert
# puts that copy back.
set -u

VER=7.3.0-rc5-next-20261002-t2
CUR="/boot/initrd.img-$VER"
BAK="/home/jc/a16-payload/ec-test-backup-20261005-080148/initrd.img-$VER"
HOOK="/etc/initramfs-tools/hooks/a16-qcom-firmware"
FW=/usr/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/home/jc/a16-payload/a16-audio-adsp-$STAMP.log"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { say "  FAIL  $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run this with sudo"

say "a16 audio / ADSP initramfs    $STAMP"
say "log: $LOG"
say ""

# ------------------------------------------------------------------ status
show_initrd() {
    local f="$1" label="$2"
    [ -f "$f" ] || { say "  $label: missing ($f)"; return; }
    say "  $label"
    say "    file      $f"
    say "    size      $(stat -c%s "$f") bytes, $(stat -c%y "$f" | cut -d. -f1)"
    # lsinitramfs needs to unpack the whole thing; count entries so a failed or
    # empty read cannot be mistaken for "the file is not in there".
    local list n
    list="$(lsinitramfs "$f" 2>/dev/null)"
    n="$(printf '%s\n' "$list" | grep -c . || true)"
    say "    entries   $n"
    if [ "$n" -lt 100 ]; then
        say "    NOTE      that is too few to be a real listing -- treat the counts"
        say "              below as unknown, not as zero."
    fi
    local m
    for m in qcadsp8480.mbn qccdsp8480.mbn adsp_dtbs.elf; do
        printf '%s\n' "$list" | grep -c "$m" | xargs -I{} printf '    %-22s %s\n' "$m" {} | tee -a "$LOG"
    done
    say "    where they are:"
    printf '%s\n' "$list" | grep -E 'qcadsp8480|qccdsp8480' | head -4 | sed 's/^/      /' | tee -a "$LOG"
    say "    /lib inside the initrd:"
    printf '%s\n' "$list" | grep -E '^/lib$|^/lib/$|^usr/lib$' | head -3 | sed 's/^/      /' | tee -a "$LOG"
}

say "WHAT IS IN THE INITRAMFS"
show_initrd "$CUR" "in /boot now (this is the one that boots)"
say ""
show_initrd "$BAK" "the one that had sound (kept from 10-04 21:27)"
say ""
say "THE HOOK"
if [ -f "$HOOK" ]; then
    say "  present: $HOOK"
else
    say "  not present: $HOOK"
fi
say ""
say "WHAT THE LAST BOOT SAID ABOUT THE ADSP"
journalctl -b -1 -k --no-pager 2>/dev/null \
    | grep -E 'remoteproc1|request_firmware' | head -6 | sed 's/^/  /' | tee -a "$LOG"
say ""
say "the firmware on the real root:"
ls -la "$FW" 2>/dev/null | tail -n +2 | awk '{printf "    %-24s %s\n", $NF, $5}' | tee -a "$LOG"
say ""

case "${1:-status}" in

status)
    say "Nothing was changed.  If the initrd in /boot has the three firmware files"
    say "under a path the kernel does not look at, that is the bug; if it has none"
    say "at all, the hook below is what puts them there."
    ;;

fix)
    say "FIX"
    say "  1. install the hook that copies the board firmware into the initramfs"
    cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
# The ADSP and CDSP take their firmware filename from the device tree, not from
# modinfo, so initramfs-tools cannot discover it on its own -- without this the
# remoteprocs are probed inside the initramfs with no firmware to load and the
# machine comes up with no sound card at all.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
for f in qcadsp8480.mbn qccdsp8480.mbn adsp_dtbs.elf cdsp_dtbs.elf; do
    src="/usr/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/$f"
    [ -f "$src" ] || continue
    if command -v manual_add_firmware >/dev/null 2>&1; then
        manual_add_firmware "$src"
    else
        mkdir -p "$DESTDIR/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA"
        cp -a "$src" "$DESTDIR/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/"
    fi
done
exit 0
HOOKEOF
    chmod 755 "$HOOK"
    say "     ok  $HOOK"

    say "  2. keep a copy of the initrd being replaced"
    cp -a "$CUR" "$CUR.before-adsp-fix-$STAMP" || die "could not back up the initrd"
    say "     ok  $CUR.before-adsp-fix-$STAMP"

    say "  3. regenerate the initramfs (this takes a minute)"
    if ! update-initramfs -u -k "$VER" >> "$LOG" 2>&1; then
        say "     FAILED -- putting the backup back"
        cp -a "$CUR.before-adsp-fix-$STAMP" "$CUR"
        die "update-initramfs failed; the previous initrd is back in place"
    fi
    say "     ok  $(stat -c%s "$CUR") bytes"

    say "  4. check the firmware is in there now"
    local_n="$(lsinitramfs "$CUR" 2>/dev/null | grep -c . || true)"
    say "     entries  $local_n"
    got="$(lsinitramfs "$CUR" 2>/dev/null | grep -c 'qcadsp8480.mbn' || true)"
    say "     qcadsp8480.mbn  $got"
    if [ "${got:-0}" -ge 1 ]; then
        say ""
        say "  PASS  the firmware is in the initramfs."
        say "        Reboot when convenient; the internal speakers should come back,"
        say "        and /proc/asound/cards should list the card again."
        say "        If the machine does not come up, the previous initrd is at"
        say "        $CUR.before-adsp-fix-$STAMP"
    else
        say ""
        say "  FAIL  the hook ran but the file is not in the initramfs."
        say "        Send me this log.  Nothing is broken -- the initrd was rebuilt"
        say "        the same way as before, so the next boot behaves as it does now."
    fi
    ;;

revert)
    say "REVERT"
    if [ -f "$HOOK" ]; then
        rm -f "$HOOK"
        say "  removed $HOOK"
    else
        say "  no hook to remove"
    fi
    update-initramfs -u -k "$VER" >> "$LOG" 2>&1 && say "  regenerated: $(stat -c%s "$CUR") bytes" \
        || say "  regenerating failed; see the log"
    ;;

*)
    say "usage: sudo bash $0 [status|fix|revert]"
    ;;
esac

say ""
say "log: $LOG"
