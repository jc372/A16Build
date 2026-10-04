#!/usr/bin/env bash
# a16-audio-attach.sh -- report why the speakers are silent, and nothing more.
#
#   bash a16-audio-attach.sh          # no root needed: reads sysfs and prints a verdict
#
# WHY THIS SCRIPT ONLY LOOKS
# --------------------------
# An earlier version of this script tried to fix the fault by re-binding the amplifier driver.
# That was a mistake worth recording: writing to /sys/bus/soundwire/drivers/*/bind when the
# SoundWire bus is in the state this fault leaves it in BLOCKS IN THE KERNEL. The process ends
# up in D state, unkillable, and the sound card is torn down while it waits -- so the machine
# goes from "one side of the speakers is silent" to "Dummy Output" and needs a reboot.
#
# So it reports only. The fix is either a reboot (which usually wins the race) or the kernel
# patch that re-enumerates the bus after a clash, which is where this should be fixed.
#
# THE FAULT IT DETECTS
# --------------------
# Four WSA8845 amplifiers, two on SoundWire master 1 and two on master 4. On some boots the pair
# on master 1 comes up "UNATTACHED" instead of "Attached", because of the race the kernel logs as
#
#   qcom-soundwire 6c80000.soundwire: qcom_swrm_irq_handler: SWR bus clsh detected
#
# With them unattached only one side routes, and the route switch reads half-on:
#
#   amixer -c 0 cget numid=95      -> values=on,off     (it should be on,on while playing)
#
# The sink, the UCM profile and the mixers all look perfectly healthy in this state, which is
# what makes it look like a PipeWire problem when it is not.
set -u

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
note() { printf '  [--]   %s\n' "$*"; }

step "the four speaker amplifiers"
N=0
for d in /sys/bus/soundwire/devices/sdw:*/; do
	[ -d "$d" ] || continue
	b=$(basename "$d"); st=$(cat "$d/status" 2>/dev/null || echo '?')
	drv=$(readlink -f "$d/driver" 2>/dev/null); drv=${drv##*/}
	[ "$st" = Attached ] || N=$((N+1))
	printf '  %-30s %-12s %s\n' "$b" "$st" "${drv:-none}"
done 2>/dev/null | sort

step "verdict"
if [ "$N" = 0 ]; then
	ok "all four amplifiers are attached"
	echo "  If the speakers are silent anyway, this is not that fault. Check, in order:"
	echo "    - is anything actually playing:  cat /proc/asound/card0/pcm1p/sub0/status"
	echo "    - the sink:                      wpctl status"
	echo "    - the route switch while playing: amixer -c 0 cget numid=95   (want on,on)"
	echo "  See docs/audio.md for the whole list."
	exit 0
fi

warn "$N amplifier(s) on the SoundWire bus are not attached -- this is the silent-speaker fault"
echo
echo "  Only the kernel can re-attach them. What is known to work:"
echo
echo "    1. Reboot. The race is per boot, so the next boot often wins it."
note "the pair that usually fails is the one on SoundWire master 1"
echo
echo "    2. The kernel-side fix, which stops the race rather than repairing it: re-enumerating"
echo "       the bus after a clash. That is work on the kernel, not something a script can do."
echo
warn "do NOT try to fix this by writing to /sys/bus/soundwire/drivers/*/bind -- it hangs in"
warn "  the kernel (unkillable D state) and takes the sound card with it. A reboot then."
echo
echo "  Evidence to keep for the kernel work, from this boot:"
echo "    journalctl -b 0 -k --no-pager | grep -iE 'swr|soundwire|wsa884'"
