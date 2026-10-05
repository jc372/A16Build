#!/bin/bash
# a16-camera-acpi-dump.sh -- collect this machine's own ACPI tables, which are the only
# authoritative statement of how the camera is wired (rails and GPIOs).  They are absent
# on the normal entries because those pass acpi=off, so this has to run from an entry
# that boots with ACPI on.
#
#   run:  sudo bash ~/a16-payload/camera/a16-camera-acpi-dump.sh
#
# It only reads /sys/firmware/acpi/tables and writes copies under ~/a16-payload/camera/acpi/.
# Nothing is modified.
set -u
K=$(uname -r); OUT=/home/jc/a16-payload/camera/acpi
echo "=== a16 camera: the machine's ACPI tables ==="
echo "  kernel : $K"
if [ ! -d /sys/firmware/acpi/tables ]; then
	echo "  [fail] /sys/firmware/acpi/tables does not exist."
	echo "         This boot has no ACPI (the usual entries pass acpi=off)."
	echo "         Boot the menu entry 'A16: installed Ubuntu 7.2 staged on the ESP (ACPI)'"
	echo "         and run me there.  That entry is documented to give a picture; HDMI gives"
	echo "         you a session if the internal panel is blank."
	exit 1
fi
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo (the tables are root-readable only)"; exit 1; }
mkdir -p "$OUT"
n=0
for t in /sys/firmware/acpi/tables/*; do
	[ -f "$t" ] || continue
	b=$(basename "$t")
	[ "$b" = "dynamic" ] && continue
	s=$(stat -c%s "$t")
	cp -f "$t" "$OUT/$b" 2>/dev/null && { n=$((n+1)); printf '  [ok] %-12s %8s bytes\n' "$b" "$s"; }
done
echo
echo "  $n table(s) written to $OUT"
if command -v acpidump >/dev/null 2>&1; then
	acpidump > "$OUT/acpidump.txt" 2>/dev/null && echo "  [ok] readable dump: $OUT/acpidump.txt ($(wc -l < "$OUT/acpidump.txt") lines)"
else
	echo "  [--] acpidump not installed; the raw tables above are enough (install acpica-tools for a readable one)"
fi
ls -la "$OUT" | tail -5 | sed 's/^/  /'
echo
echo "  tell the agent these exist; it will read the PEP/DSDT and name the camera's rails"
echo "  and its reset/power GPIOs from them instead of from inference."
