#!/usr/bin/env bash
# a16-fix-dsp.sh - install the A16 ADSP/CDSP firmware and bring the DSPs up.
#
# WHY (evidence: this boot's kernel log)
#   remoteproc0/1 (adsp, cdsp) are the glymur DTB's nodes. The DTB names firmware under
#     /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/
#   linux-firmware ships only the generic qcom/glymur/adsp.mbn + cdsp.mbn, so both failed:
#     Direct firmware load for qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn failed with error -2
#     request_firmware failed: -2          ->  both remoteprocs stay offline
#   With the ADSP down nothing hosts the LPASS services:
#     - pinctrl@7760000 clocks come from /soc@0/remoteproc@6800000/glink-edge/gpr/service@2/
#       clock-controller (qcom,q6prm-lpass-clocks) -> no clocks -> pinctrl defers ->
#       soundwire@6c80000/6ca00000, codec@7660000/6c90000/6cb0000 and /sound all defer = no sound
#     - qcom-battmgr's PMIC-glink queries are answered by firmware -> every attribute returns
#       "Resource temporarily unavailable" = no battery, no AC, no charge state
#
# RUN:  sudo bash /home/jc/a16-payload/a16-fix-dsp.sh
# OUT:  /home/jc/a16-payload/A16DSP.LOG   (readable as jc; also echoed to the terminal)

set -u

SRC=/home/jc/a16-payload/a16-local-firmware/qcom/glymur/ASUSTeK/UX3607OA
DST=/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA
LOG=/home/jc/a16-payload/A16DSP.LOG

if [ "$(id -u)" -ne 0 ]; then
    echo "run this with sudo:  sudo bash $0"
    exit 1
fi

# log everything to the terminal and to a file jc can read afterwards
exec > >(tee "$LOG") 2>&1

echo "=== a16-fix-dsp $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo "kernel: $(uname -r)"
echo "cmdline: $(tr -s ' ' < /proc/cmdline)"
echo

echo "=== verify the four blobs against the hashes recorded in the repo ==="
declare -A WANT=(
  [qcadsp8480.mbn]=67b4e129d4d60fccd05d85be3754168f46535549a03a3627c598d634e73df49d
  [adsp_dtbs.elf]=7906466c734b2f360d48cf086f80b6e04d84e9b02255c74545aa28d5df1e932c
  [qccdsp8480.mbn]=acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794
  [cdsp_dtbs.elf]=9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d
)
bad=0
for f in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf; do
    if [ ! -f "$SRC/$f" ]; then echo "MISSING  $SRC/$f"; bad=1; continue; fi
    got=$(sha256sum "$SRC/$f" | cut -d' ' -f1)
    if [ "$got" = "${WANT[$f]}" ]; then echo "OK       $f"; else echo "MISMATCH $f got=$got want=${WANT[$f]}"; bad=1; fi
done
if [ "$bad" -ne 0 ]; then echo "refusing to install unverified firmware"; exit 1; fi
echo

echo "=== install into $DST ==="
mkdir -p "$DST"
for f in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf; do
    install -m 0644 -v "$SRC/$f" "$DST/$f" 2>&1
done
sync
echo "--- installed ---"
ls -la "$DST"
sha256sum "$DST"/* 2>&1
echo

rp_dump() {
    for r in /sys/class/remoteproc/*; do
        [ -d "$r" ] || continue
        printf '%-14s name=%-6s state=%-10s firmware=%s\n' "$(basename "$r")" \
            "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null)" "$(cat "$r/firmware" 2>/dev/null)"
    done
}

echo "=== remoteproc before ==="
rp_dump
echo

echo "=== start the DSPs (remoteproc sysfs) ==="
for r in /sys/class/remoteproc/*; do
    [ -d "$r" ] || continue
    name=$(cat "$r/name" 2>/dev/null)
    st=$(cat "$r/state" 2>/dev/null)
    if [ "$st" = "offline" ]; then
        echo "-- starting $(basename "$r") ($name)"
        if ! echo start > "$r/state" 2>/tmp/a16dsp.err; then
            echo "   start failed: $(cat /tmp/a16dsp.err)"
        fi
    else
        echo "-- $(basename "$r") ($name) already $st"
    fi
done

echo "-- waiting up to 20 s for the DSPs to report"
i=0
while [ "$i" -lt 20 ]; do
    running=0
    for r in /sys/class/remoteproc/*; do
        [ "$(cat "$r/state" 2>/dev/null)" = "running" ] && running=$((running+1))
    done
    [ "$running" -ge 1 ] && { sleep 3; break; }
    sleep 1
    i=$((i+1))
done
echo

echo "=== remoteproc after ==="
rp_dump
echo

echo "=== what the DSPs said (fresh kernel log, relevant lines) ==="
journalctl -k -b --no-pager 2>/dev/null | tail -400 \
    | grep -iE 'remoteproc|adsp|cdsp|q6v5|q6prm|gpr|glink|battmgr|soundwire|x1e80100|snd|pinctrl|smd|fastrpc' \
    | tail -60
echo

echo "=== battery / AC (qcom-battmgr) ==="
for ps in qcom-battmgr-bat qcom-battmgr-ac; do
    echo "-- $ps"
    for a in type status capacity capacity_level voltage_now power_now charge_control_end_threshold cycle_count; do
        printf '   %-32s %s\n' "$a:" "$(cat /sys/class/power_supply/$ps/$a 2>&1)"
    done
done
echo

echo "=== sound ==="
echo "-- /proc/asound/cards"
cat /proc/asound/cards 2>&1
echo "-- /sys/class/sound"
ls /sys/class/sound 2>&1
echo "-- modules holding the sound chain"
lsmod 2>/dev/null | grep -iE 'snd_soc_x1e80100|snd_soc_qcom_sdw|lpass|q6prm|gpr|soundwire' | head -20
echo

echo "=== deferred probes now ==="
cat /sys/kernel/debug/devices_deferred 2>&1 | head -20
echo

echo "=== summary ==="
for r in /sys/class/remoteproc/*; do
    printf '%-14s %s = %s\n' "$(basename "$r")" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null)"
done
echo "battery: type=$(cat /sys/class/power_supply/qcom-battmgr-bat/type 2>&1) status=$(cat /sys/class/power_supply/qcom-battmgr-bat/status 2>&1) capacity=$(cat /sys/class/power_supply/qcom-battmgr-bat/capacity 2>&1)"
echo "sound:   $(head -2 /proc/asound/cards 2>/dev/null | tail -1)"
echo
echo "log written to $LOG"
echo "=== done $(date '+%H:%M:%S') ==="

chown jc:jc "$LOG" 2>/dev/null
exit 0
