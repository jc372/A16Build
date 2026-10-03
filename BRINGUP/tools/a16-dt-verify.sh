#!/usr/bin/env bash
# a16-dt-verify.sh -- after booting the "[1] ... DT test" entry, run this to
# collect the evidence for whether the internal input devices appeared.
# Needs no root; writes one log file.
#
#     bash /home/jc/a16-payload/a16-dt-verify.sh
#
# Design rules (arm64-laptop-bringup): the tarball/log is the data, the screen is
# a bonus; never fail hard; keep stdout AND stderr AND exit codes.
set -u

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
ESP="${A16_ESP:-/boot/efi}"
if touch "$ESP/.a16v" 2>/dev/null; then rm -f "$ESP/.a16v"; OUT="$ESP/A16DTVERIFY-$STAMP.log"; else OUT="/home/jc/a16-payload/A16DTVERIFY-$STAMP.log"; fi
: > "$OUT"
say() { printf '[a16-verify] %s\n' "$*" | tee -a "$OUT"; }
cap() { # cap <label> <cmd...>
  local label="$1"; shift
  { echo "### $label"; echo "\$ $*"; "$@" 2>&1; echo "### exit: $?"; echo; } | tee -a "$OUT" >/dev/null
}
caps() { local label="$1"; shift; { echo "### $label"; echo "\$ $*"; bash -c "$*" 2>&1; echo "### exit: $?"; echo; } | tee -a "$OUT" >/dev/null; }

say "=== a16-dt-verify $STAMP ==="
say "log: $OUT"
cap identity uname -a
cap cmdline cat /proc/cmdline
caps dmidecode-ish 'for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_version; do printf "%s: %s\n" "$f" "$(cat $f 2>/dev/null)"; done'
cap uptime uptime
cap date date

say "--- input devices ---"
cap input-devices cat /proc/bus/input/devices
cap input-class ls -l /sys/class/input
cap input-bypath ls -l /dev/input/by-path
caps evdev-count 'ls /dev/input/event* 2>/dev/null | wc -l'
caps internal-names 'grep -aiE "^N: Name=" /proc/bus/input/devices | grep -viE "logitech|keychron|power button|video bus|pc speaker"'

say "--- i2c ---"
cap i2c-devices ls -l /sys/bus/i2c/devices
caps i2c-adapters 'compgen -G "/sys/class/i2c-adapter/*" >/dev/null || { echo "(none: no i2c adapter exists)"; exit 0; }; for a in /sys/class/i2c-adapter/*; do printf "%s: %s\n" "$(basename $a)" "$(cat $a/name 2>/dev/null)"; done'
caps i2c-clients 'compgen -G "/sys/bus/i2c/devices/*" >/dev/null || { echo "(none: no i2c bus, so no client devices)"; exit 0; }; for d in /sys/bus/i2c/devices/*; do if [ -L "$d/driver" ]; then drv=$(basename $(readlink -f "$d/driver")); else drv="(no driver)"; fi; printf "%s  name=%s  driver=%s\n" "$(basename $d)" "$(cat $d/name 2>/dev/null)" "$drv"; done'
caps hidraw 'ls -l /dev/hidraw* 2>/dev/null; cat /sys/class/hidraw/*/device/uevent 2>/dev/null | grep -iE "HID_NAME|HID_ID"'

say "--- gpio / pinctrl ---"
cap gpio-class ls -l /sys/class/gpio
caps gpiochips 'compgen -G "/sys/class/gpio/gpiochip*" >/dev/null || { echo "(none: no gpio controller registered)"; exit 0; }; for g in /sys/class/gpio/gpiochip*; do printf "%s base=%s ngpio=%s label=%s\n" "$(basename $g)" "$(cat $g/base 2>/dev/null)" "$(cat $g/ngpio 2>/dev/null)" "$(cat $g/label 2>/dev/null)"; done'
caps pinctrl-bound 'for d in /sys/bus/platform/drivers/pinctrl-glymur /sys/bus/platform/drivers/pinctrl-msm; do echo "$d:"; ls $d 2>/dev/null | grep -v "^bind$\|^unbind$\|^uevent$\|^module$\|^new_id$"; done'

say "--- modules ---"
cap lsmod-input 'lsmod'
caps modules-filter 'lsmod | grep -iE "i2c|hid|pinctrl|gpio|glymur|geni"'

say "--- kernel log (this boot), filtered ---"
caps log-filtered 'journalctl -k -b --no-pager 2>/dev/null | grep -iE "i2c|hid|pinctrl|tlmm|glymur|geni|qup|input|QTEC|MSFT|asustek|elan" | tail -120'
caps log-errors 'journalctl -b --no-pager -p err 2>/dev/null | tail -40'
caps log-tail 'journalctl -k -b --no-pager 2>/dev/null | tail -30'

say "--- ACPI view for comparison (are the PNP0C50 devices driverless?) ---"
caps acpi-pnp0c50 'for d in /sys/bus/acpi/devices/*/; do m=$(cat $d/modalias 2>/dev/null); case "$m" in *PNP0C50*) if [ -L "$d/driver" ]; then drv=$(basename $(readlink -f "$d/driver")); else drv="(no driver)"; fi; printf "%s sta=%s driver=%s modalias=%s path=%s\n" "$(basename $d)" "$(cat $d/status 2>/dev/null)" "$drv" "$m" "$(cat $d/path 2>/dev/null)";; esac; done'

say "=== summary ==="
say "input devices:   $(grep -ac '^N: Name=' /proc/bus/input/devices)"
say "i2c adapters:    $(ls -d /sys/class/i2c-adapter/* 2>/dev/null | wc -l)"
say "i2c clients:     $(ls -d /sys/bus/i2c/devices/* 2>/dev/null | wc -l)"
say "gpiochips:       $(ls -d /sys/class/gpio/gpiochip* 2>/dev/null | wc -l)"
say "hidraw nodes:    $(ls /dev/hidraw* 2>/dev/null | wc -l)"
say "cmdline:         $(cat /proc/cmdline)"
say "log file:        $OUT"
say "=== copy this log back with the stick ==="
