#!/usr/bin/env bash
# a16-audio-attach.sh -- re-attach the speaker amplifiers when a boot loses the SoundWire race.
#
#   sudo bash a16-audio-attach.sh                 # report, then retry the attach if needed
#   sudo bash a16-audio-attach.sh --check         # report only, change nothing
#   sudo bash a16-audio-attach.sh --install-service   # after this works: do it at every boot
#   sudo bash a16-audio-attach.sh --remove-service    # take that boot-time job out again
#
# The fault this exists for: two of the four WSA8845 amplifiers (the pair on SoundWire master 1)
# come up "UNATTACHED" instead of "Attached", the card only routes one side, and the machine is
# silent with a perfectly healthy-looking PipeWire sink. The kernel says so at boot:
#
#   qcom-soundwire 6c80000.soundwire: qcom_swrm_irq_handler: SWR bus clsh detected
#
# Nothing here touches anything but those four amplifiers and, if the first step is not enough,
# the SoundWire controller that drives them. The video/sink is not restarted from root on purpose
# (a root process must not poke another user's session bus) -- the last line tells you what to do.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }

MODE=fix
case "${1:-}" in
	--check) MODE=check ;;
	--install-service) MODE=install ;;
	--remove-service) MODE=remove ;;
	-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
	'') : ;;
	*) echo "unknown option: $1 (try --help)"; exit 2 ;;
esac

DRV=/sys/bus/soundwire/drivers/wsa884x-codec
CTRL=6c80000.soundwire
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
bad()  { printf '  [fail] %s\n' "$*"; }

state() {   # prints one line per amp: name, status, driver
	for d in /sys/bus/soundwire/devices/sdw:*/; do
		[ -d "$d" ] || continue
		b=$(basename "$d")
		drv=$(readlink -f "$d/driver" 2>/dev/null); drv=${drv##*/}
		printf '  %-30s %-12s %s\n' "$b" "$(cat "$d/status" 2>/dev/null || echo '?')" "${drv:-none}"
	done
}
unattached() { grep -l 'UNATTACHED' /sys/bus/soundwire/devices/sdw:*/status 2>/dev/null | wc -l; }
attached_count() { grep -l 'Attached' /sys/bus/soundwire/devices/sdw:*/status 2>/dev/null | wc -l; }

step "the four speaker amplifiers"
state
N=$(unattached)
printf '  attached: %s/4\n' "$(attached_count)"
if [ "$N" = 0 ]; then
	ok "all four are attached -- this is not the fault, nothing to retry"
	echo "  If the speakers are silent anyway, check the sink and the player's own volume,"
	echo "  and that something is actually playing: /proc/asound/card0/pcm1p/sub0/status"
	exit 0
fi
warn "$N amplifier(s) not attached -- this is the fault"

if [ "$MODE" = check ]; then
	echo
	echo "  --check only; run again without it to retry the attach."
	exit 0
fi

step "retry 1: bind the missing amplifier(s) again"
for d in /sys/bus/soundwire/devices/sdw:*/; do
	b=$(basename "$d")
	[ "$(cat "$d/status" 2>/dev/null)" = UNATTACHED ] || continue
	printf '  %s: unbind/bind\n' "$b"
	[ -w "$DRV/unbind" ] && echo "$b" > "$DRV/unbind" 2>/dev/null || warn "could not unbind $b"
	sleep 1
	[ -w "$DRV/bind" ] && echo "$b" > "$DRV/bind" 2>/dev/null || warn "could not bind $b"
	sleep 1
done
state
if [ "$(unattached)" = 0 ]; then
	ok "all four attached now"
else
	bad "$(unattached) still unattached after re-binding"
	step "retry 2: re-enumerate the SoundWire controller ($CTRL)"
	CBI=/sys/bus/platform/devices/$CTRL
	if [ -d "$CBI" ] && [ -w "$CBI/driver/unbind" ]; then
		warn "this rebinds the bus every amplifier sits on -- if it goes wrong, sound is no worse"
		D=$(readlink -f "$CBI/driver"); D=${D##*/}
		echo "$CTRL" > "$CBI/driver/unbind" 2>/dev/null && sleep 2 && echo "$CTRL" > "/sys/bus/platform/drivers/$D/bind" 2>/dev/null
		sleep 3
		state
		[ "$(unattached)" = 0 ] && ok "all four attached after the controller re-enumerated" \
			|| bad "still $(unattached) unattached -- a reboot is the remaining option"
	else
		warn "cannot find a writable driver for $CTRL -- skipping"
	fi
fi

step "what to do next"
if [ "$(unattached)" = 0 ]; then
	cat <<'EOF'
  Start playback again (or pause and play) so the card re-opens the route, then check:

      amixer -c 0 cget numid=95          # should read: values=on,on

  If it reads on,on while something is playing, the speakers are back. To have this retried at
  every boot automatically:

      sudo bash a16-audio-attach.sh --install-service
EOF
else
	echo "  Unresolved on this boot. The kernel needs the SoundWire patch that re-enumerates after"
	echo "  a clash; a reboot into the same kernel usually wins the race."
fi

if [ "$MODE" = install ]; then
	step "boot-time service"
	# the unit runs a root-owned copy: a root service must not execute a file the user can edit
	install -m 0755 "$0" /usr/local/sbin/a16-audio-attach.sh && ok "installed the script to /usr/local/sbin"
	cat > /etc/systemd/system/a16-audio-attach.service <<EOF
[Unit]
Description=A16: retry the SoundWire attach for the speaker amplifiers if a boot loses the race
After=sound.target multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/a16-audio-attach.sh --check
ExecStartPost=/usr/local/sbin/a16-audio-attach.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload && systemctl enable --now a16-audio-attach.service \
		&& ok "installed and enabled: a16-audio-attach.service" \
		|| bad "could not enable the service"
	echo "  It runs once per boot, does nothing when all four are attached, and retries when not."
	echo "  Remove it again with:  sudo bash $0 --remove-service"
fi

if [ "$MODE" = remove ]; then
	step "removing the boot-time service"
	systemctl disable --now a16-audio-attach.service 2>/dev/null
	rm -f /etc/systemd/system/a16-audio-attach.service
	systemctl daemon-reload
	ok "service removed"
fi
