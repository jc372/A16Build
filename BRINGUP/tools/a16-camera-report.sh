#!/usr/bin/env bash
# a16-camera-report.sh -- collect everything the camera step-1 test can produce,
# in one file, whether or not the desktop ever comes up.
#
#   bash ~/a16-payload/camera/a16-camera-report.sh      # by hand
#   (a16-camera-step1.sh also installs it as a oneshot service, so a boot that
#    uses the camera DTB leaves a log without anyone typing anything)
#
# Read-only.  It writes one file under ~/a16-payload/camera/logs/ and prints the
# verdict it can see, nothing more.
set -u

LOGDIR=/home/jc/a16-payload/camera/logs
mkdir -p "$LOGDIR"
BOOTID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
LOG="$LOGDIR/boot-${BOOTID:-unknown}.log"
# a boot_id is stable per boot, so a second run in the same boot appends rather
# than overwriting: the interesting state is the difference between the two.
{
echo "=== a16 camera report $(date 2>/dev/null) (boot $BOOTID) ==="
echo "--- kernel / cmdline"
uname -a
tr '\0' ' ' < /proc/cmdline; echo
echo
echo "--- which device tree is loaded"
if [ -e /proc/device-tree/model ]; then tr '\0' '\n' < /proc/device-tree/model; fi
for n in "soc@0/cci@ac15000" "soc@0/cci@ac16000"; do
	p="/proc/device-tree/$n"
	if [ -e "$p" ]; then printf '  %-22s present, status=%s\n' "$n" "$(tr -d '\0' < "$p/status" 2>/dev/null)"; else printf '  %-22s ABSENT\n' "$n"; fi
done
for p in /proc/device-tree/soc@0/cci@*/*/camera@36 /proc/device-tree/soc@0/cci@*/i2c-bus@*; do
	[ -d "$p" ] || continue
	printf '  %s -> %s\n' "${p#/proc/device-tree/}" "$(tr -d '\0' < "$p/compatible" 2>/dev/null)"
done
echo
echo "--- modules of interest (loaded?)"
for m in i2c_qcom_cci ov02c10 ov08x40 qcom_camss videobuf2_common v4l2_async camcc_glymur pinctrl_glymur qcom_rpmh_regulator; do
	printf '  %-22s %s\n' "$m" "$(lsmod | awk -v m="$m" '$1==m{print "loaded ("$3" users)"}' | head -1)"
done
echo
echo "--- i2c buses the CCI registered  (read from /sys/bus, which works unprivileged)"
for d in /sys/bus/i2c/devices/i2c-*; do
	[ -d "$d" ] || continue
	n="$(cat "$d/name" 2>/dev/null)"
	case "$n" in *CCI*) printf '  %-6s %s\n' "${d##*/}" "$n";; esac
done
echo
echo "--- i2c clients on the CCI buses (the sensor is 0x36)"
for d in /sys/bus/i2c/devices/*; do
	[ -e "$d" ] || continue
	drv="$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
	printf '  %-10s name=%-14s driver=%s\n' "${d##*/}" "$(cat "$d/name" 2>/dev/null)" "${drv:-<none>}"
done
echo
echo "--- pinctrl: is the camera mux applied"
if [ -d /sys/kernel/debug/pinctrl ]; then
	for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
		[ -f "$f" ] || continue
		grep -E "pin (100|101|102|103|104|105|106|235|236) " "$f" 2>/dev/null | sed 's/^/  /'
	done
fi
echo
echo "--- video devices (a working pipeline shows /dev/video* and /dev/media*)"
ls -l /dev/video* /dev/media* 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo "--- regulators (camera rails present?"
if [ -r /sys/kernel/debug/regulator/regulator_summary ]; then
	sed -n '1,3p' /sys/kernel/debug/regulator/regulator_summary | sed 's/^/  /'
	grep -E 'l4i_e0|l7i_e0|vreg_l4i_e0|vreg_l7i_e0' /sys/kernel/debug/regulator/regulator_summary | sed 's/^/  /'
fi
for r in /sys/class/regulator/*/name; do
	v="$(cat "$r" 2>/dev/null)"
	case "$v" in *l4i_e0*|*l7i_e0*) printf '  %s = %s uV, state=%s\n' "$v" "$(cat "${r%name}"microvolts 2>/dev/null)" "$(cat "${r%name}state" 2>/dev/null)";; esac
done
echo
echo "--- dmesg: cci / ov02c10 / camss / camcc / regulator, whole lines"
dmesg 2>/dev/null | grep -iE 'cci|ov02c10|ov08x40|ov08x|camss|csiphy|csid|vfe|camcc|cam_cc|titan|vreg_l4i|vreg_l7i|pmh0104|rpmh.*(ldo4_i|ldo7_i)' | sed 's/^/  /'
echo
echo "--- dmesg: deferred probes and probe failures left over"
dmesg 2>/dev/null | grep -iE 'defer|probe.*fail|could not find RPMh|unknown regulator|not enough clocks|parsing endpoint|chip ID' | tail -25 | sed 's/^/  /'
echo
echo "--- dmesg: the tail, whatever it says"
dmesg 2>/dev/null | tail -20 | sed 's/^/  /'
echo
echo "=== end of report (boot $BOOTID) ==="
} >> "$LOG" 2>&1

# ---------------------------------------------------------------- verdict
echo "log: $LOG"
echo
echo "--- what this boot shows"
if [ ! -e /proc/device-tree/soc@0/cci@ac16000 ]; then
	echo "  the camera device tree is NOT loaded -- this boot proves nothing about it"
	echo "  (pick the camera entry in the menu, or run: sudo bash ~/a16-payload/camera/a16-camera-step1.sh)"
	exit 0
fi
cci_n="$(for d in /sys/bus/i2c/devices/i2c-*; do [ -d "$d" ] || continue; n=$(cat "$d/name" 2>/dev/null); case "$n" in *CCI*) echo "$n";; esac; done | wc -l)"
echo "  device tree      : camera nodes present"
echo "  CCI i2c adapters : $cci_n (expect 2: the two masters of cci1)"
if ls /sys/bus/i2c/devices/*-0036 >/dev/null 2>&1; then
	echo "  sensor client    : present at 0x36"
	drv="$(basename "$(readlink -f /sys/bus/i2c/devices/*-0036/driver 2>/dev/null)" 2>/dev/null)"
	if [ -n "$drv" ]; then echo "  sensor driver    : BOUND ($drv)  <-- the sensor answered on I2C"
	else echo "  sensor driver    : not bound -- read the dmesg lines above for why"; fi
else
	echo "  sensor client    : absent at 0x36 (nothing bound a device there)"
fi
# what the probe actually did, and what the i2c errno means
err="$(dmesg 2>/dev/null | grep -iE 'ov02c10|ov08x40'  | tail -1)"
case "$err" in
	*'-6'*)   echo "  chip id          : NOT read -- -6 is -ENXIO, the transfer finished and the sensor did not ACK."
	          echo "                     that is a power/reset problem on the sensor side, not the CCI" ;;
	*'-110'*) echo "  chip id          : NOT read -- -110 is -ETIMEDOUT: the CCI never completed, so suspect the irq/clock" ;;
	*'')      : ;;
	*)        echo "  chip id          : $err" ;;
esac
if dmesg 2>/dev/null | grep -qE '(ov02c10|ov08x40).*chip-id register: -6'; then
	echo "                     CCI, pins, reset gpio and MCLK are nevertheless proven" >/dev/null
fi
echo
echo "  next: read $LOG, or let the next session read it."
