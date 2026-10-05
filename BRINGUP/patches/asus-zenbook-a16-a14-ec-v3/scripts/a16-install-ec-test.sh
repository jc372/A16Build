#!/bin/bash
# a16 EC test kernel -- run with: sudo bash ~/a16-payload/a16-install-ec-test.sh [read]
#
# Installs the kernel built with Konrad Dybcio's v3 EC driver into /boot,
# leaving the boot default where it is. Two phases:
#   (no argument) install the new Image and rebuild the initramfs
#   read          print the EC values, to compare against the baseline

set -u

VER=7.3.0-rc5-next-20261002-t2
TREE=/home/jc/build/next-20261002-repull
IMG="$TREE/arch/arm64/boot/Image"
PAY=/home/jc/a16-payload
DIR="$PAY/asus-zenbook-a16-a14-ec-v3"
mkdir -p "$DIR/evidence"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="${1:-install}"

say() { printf '%s\n' "$*"; }
die() { say ""; say "STOPPED: $*"; say "Nothing further was changed."; exit 1; }

# ---------------------------------------------------------------- read phase
if [ "$MODE" = read ]; then
	H=""
	for h in /sys/class/hwmon/hwmon*; do
		[ -r "$h/name" ] || continue
		[ "$(cat "$h/name" 2>/dev/null)" = asus_glymur_ec ] && H="$h"
	done
	say "=== what is running ==="
	say "  kernel   : $(uname -r)"
	say "  Image    : $(sha256sum "/boot/vmlinuz-$(uname -r)" 2>/dev/null | cut -c1-24)"
	say ""
	say "=== the EC ==="
	if [ -z "$H" ]; then
		say "  asus_glymur_ec is NOT present."
		say "  That means the driver did not bind. Send me this output."
		exit 1
	fi
	say "  hwmon    : $H  ($(cat "$H/name"))"
	say "  fan1     : $(cat "$H/fan1_input" 2>/dev/null) RPM"
	say "  fan2     : $(cat "$H/fan2_input" 2>/dev/null) RPM"
	say "  temp1    : $(cat "$H/temp1_input" 2>/dev/null)  label $(cat "$H/temp1_label" 2>/dev/null)"
	say "  temp2    : $(cat "$H/temp2_input" 2>/dev/null)  label $(cat "$H/temp2_label" 2>/dev/null)"
	say "  kbd backl: $(cat /sys/class/leds/asus::kbd_backlight/brightness 2>/dev/null) of $(cat /sys/class/leds/asus::kbd_backlight/max_brightness 2>/dev/null)"
	say "  bound to : $(basename "$(readlink -f /sys/bus/i2c/devices/9-0076/driver 2>/dev/null)")"
	say ""
	say "  suspend/resume hooks are built in; the EC gets told when the system"
	say "  suspends. That is only exercised by an actual suspend."
	exit 0
fi

# ------------------------------------------------------------- install phase
[ "$MODE" = install ] || die "unknown phase '$MODE' -- use 'install' or 'read'"
[ "$(id -u)" = 0 ] || die "installing needs root:  sudo bash ~/a16-payload/a16-install-ec-test.sh install"
[ -f "$IMG" ] || die "no Image at $IMG -- build it first"
[ -f "$TREE/drivers/platform/arm64/asus-glymur-ec.c" ] || die "the EC driver source is not in the tree"

NEW_SHA="$(sha256sum "$IMG" | cut -d' ' -f1)"
CUR_BOOT="/boot/vmlinuz-$VER"
[ -f "$CUR_BOOT" ] || die "no $CUR_BOOT -- this kernel was not installed from a package; refusing to guess"

BACKUP="$PAY/ec-test-backup-$STAMP"
say "a16 EC test kernel -- phase: install"
say "date: $(date)"
say ""
say "INSTALL -- replaces vmlinuz of $VER; the boot default does not move"
say "  tree Image : $IMG"
say "  size       : $(du -h "$IMG" | cut -f1)"
say "  sha256     : $(printf '%s' "$NEW_SHA" | cut -c1-24)"
say "  in /boot   : $(sha256sum "$CUR_BOOT" | cut -c1-24)  (current)"
say ""
if [ "$(sha256sum "$CUR_BOOT" | cut -d' ' -f1)" = "$NEW_SHA" ]; then
	say "ALREADY INSTALLED -- the Image in /boot is already this build."
	say "Nothing to do. If you meant to test it, reboot and run: read"
	exit 0
fi

say "  1/4 saving the current kernel so this is reversible"
mkdir -p "$BACKUP"
cp -a "$CUR_BOOT" "$BACKUP/vmlinuz-$VER" || die "could not back up the current kernel"
[ -f "/boot/initrd.img-$VER" ] && cp -a "/boot/initrd.img-$VER" "$BACKUP/initrd.img-$VER"
say "     saved to $BACKUP"

say "  2/4 installing the new Image"
install -m 0644 "$IMG" "$CUR_BOOT" || die "could not write $CUR_BOOT"

say "  3/4 rebuilding the initramfs"
if ! mkinitramfs -o "/boot/initrd.img-$VER" "$VER" >> "$DIR/evidence/a16-install-ec-test-$STAMP.log" 2>&1; then
	cp -a "$BACKUP/vmlinuz-$VER" "$CUR_BOOT"
	die "mkinitramfs failed; the previous kernel was put back. Log: $DIR/evidence/a16-install-ec-test-$STAMP.log"
fi
say "     ok  $(du -h "/boot/initrd.img-$VER" | cut -f1)"

say "  4/4 verifying"
GOT="$(sha256sum "$CUR_BOOT" | cut -d' ' -f1)"
[ "$GOT" = "$NEW_SHA" ] || die "the installed Image does not match the tree build"
say "     /boot Image matches the tree build"
say ""
say "Done."
say "  Reboot, then run:  bash ~/a16-payload/a16-install-ec-test.sh read"
say ""
say "  What each outcome means after the reboot:"
say "    asus_glymur_ec appears with fan1/fan2/temps  -> his v3 binds on the A16"
say "    the same numbers as the baseline              -> behaves identically to ours"
say "    the driver is absent                          -> it failed; we still have"
say "                                                     the old Image in $BACKUP"
say ""
say "  The boot default is still t1, so if this kernel is bad the machine"
say "  still boots. Send me the read output either way."
say "  Log: $DIR/evidence/a16-install-ec-test-$STAMP.log"
