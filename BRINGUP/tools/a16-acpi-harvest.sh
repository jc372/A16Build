#!/bin/bash
# a16-acpi-harvest.sh -- get the machine's ACPI tables without a usable console.
#
#   report:  sudo bash ~/a16-payload/camera/a16-acpi-harvest.sh
#   apply:   sudo bash ~/a16-payload/camera/a16-acpi-harvest.sh --apply
#
# Why: the ACPI tables only exist on a boot without acpi=off, and acpi=off is what gives this
# machine its panel, keyboard and trackpad.  So the ACPI boot is blind by construction -- you
# cannot log into it and run anything.  Instead:
#
#   * one systemd unit is installed on the root filesystem, gated by
#     ConditionKernelCommandLine=acpi.harvest=1, so it is inert on every normal boot
#   * one menu entry ("ACPI harvest") clones the existing, known-booting ACPI entry verbatim
#     and appends only acpi.harvest=1 to its cmdline -- same clone-don't-author rule as the
#     recovery entries (a hand-written block shipped an unset UUID once and reported
#     "kernel or initramfs missing")
#   * boot it: the screen stays black, no keyboard; the unit runs acpidump, writes the tables
#     where you can read them, writes its own log, and reboots the machine
#
# Nothing is added to the ACPI entry itself, and no normal entry passes acpi.harvest=1, so the
# unit can never fire on a boot where you need the display.

set -u
STAMP=$(date +%Y%m%d-%H%M%S)
ARCH=/home/jc/a16-payload/camera/grub-archive/$STAMP
OUTDIR=/home/jc/a16-payload/camera/acpi
HELPER=/usr/local/lib/a16-acpi-harvest.sh
UNIT=/etc/systemd/system/a16-acpi-harvest.service
EXIST_TITLE='A16: ACPI dump (t2 kernel, ACPI on, no device tree)'
NEW_TITLE='A16: ACPI harvest (unattended: dump tables, then reboot)'
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

echo "=== a16-acpi-harvest ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo"; exit 1; }
echo "  mode: $([ "$APPLY" = 1 ] && echo APPLY || echo 'report only')"
echo "  tables will land in: $OUTDIR"
echo "  unit:                $UNIT"
echo "  entry:               $NEW_TITLE"
command -v acpidump >/dev/null || { echo "  [fail] acpidump is not installed (acpica-tools)"; exit 1; }
echo "  acpidump: $(command -v acpidump)"
echo

# --- what would be installed -----------------------------------------------------------------
echo "--- the unit (runs only with acpi.harvest=1 on the cmdline) ---"
cat <<'UNITSHOW' | sed 's/^/  /'
[Unit]
Description=A16: dump the ACPI tables, then reboot
ConditionKernelCommandLine=acpi.harvest=1
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/a16-acpi-harvest.sh
ExecStartPost=/bin/systemctl --no-block reboot

[Install]
WantedBy=multi-user.target
UNITSHOW
echo

# --- the menu entries -------------------------------------------------------------------------
python3 - "$APPLY" "$ARCH" "$EXIST_TITLE" "$NEW_TITLE" $MENUS <<'PY'
import os, re, sys
apply_, arch, exist_t, new_t = sys.argv[1] == "1", sys.argv[2], sys.argv[3], sys.argv[4]
for menu in sys.argv[5:]:
	if not os.path.exists(menu):
		print(f"--- {menu}: absent"); continue
	s = open(menu).read()
	ent = list(re.finditer(r'^menuentry\s+"([^"]+)"\s*\{(.*?)^\}', s, re.S | re.M))
	names = [b.group(1) for b in ent]
	base = next((b.group(0) for b in ent if b.group(1) == exist_t), None)
	print(f"--- {menu}")
	print(f"      entries {len(names)}; the ACPI entry is here: {'yes' if base else 'no'}; harvest entry already here: {'yes' if new_t in names else 'no'}")
	if not base:
		print("      (no ACPI entry in this menu -- nothing to clone, skipping)"); continue
	if new_t in names:
		print("      [ok] already installed here"); continue
	if not apply_:
		print(f"      [check] would clone it verbatim and append only: acpi.harvest=1")
		continue
	blk = re.sub(r'^menuentry\s+"[^"]+"', f'menuentry "{new_t}"', base, count=1, flags=re.M)
	blk = re.sub(r'^([ \t]*linux\s+.*?)\s*$', lambda m: m.group(1) + ' acpi.harvest=1', blk, count=1, flags=re.M)
	blk = '# cloned from "' + exist_t + '" by a16-acpi-harvest.sh\n' + blk + "\n"
	os.makedirs(arch, exist_ok=True)
	open(os.path.join(arch, os.path.basename(os.path.dirname(menu)) + '.grub.cfg'), 'w').write(s)
	anchor = re.search(r'^menuentry\s+"' + re.escape(exist_t) + r'"\s*\{.*?^\}', s, re.S | re.M)
	out = s[:anchor.end()] + "\n\n" + blk + s[anchor.end():]
	open(menu + '.new', 'w').write(out); os.replace(menu + '.new', menu)
	cur = open(menu).read()
	b = re.search(r'^menuentry\s+"' + re.escape(new_t) + r'"\s*\{(.*?)^\}', cur, re.S | re.M)
	cmd = re.search(r'^\s*linux\s+(.*)$', b.group(1), re.M).group(1) if b else '(absent)'
	uuid = re.search(r'--set=root\s+(\S+)', b.group(1), re.M) if b else None
	print(f"      [ok] added ({len(re.findall(r'^menuentry', cur, re.M))} entries now)")
	print(f"           uuid={uuid.group(1) if uuid else '!! MISSING'}")
	print(f"           tail=...{cmd[-70:]}")
PY

# --- the helper and the unit ------------------------------------------------------------------
if [ "$APPLY" != 1 ]; then
	echo
	echo "--- Nothing changed.  Run with --apply."
	exit 0
fi

mkdir -p "$OUTDIR"
cat > "$HELPER" <<'HELP'
#!/bin/bash
# Runs once, only on a boot with acpi.harvest=1.  Dumps the ACPI tables, then reboots.
set -u
OUT=/home/jc/a16-payload/camera/acpi
LOG=$OUT/harvest.log
mkdir -p "$OUT"
{
	echo "=== a16 ACPI harvest $(date -Is) ==="
	echo "cmdline: $(cat /proc/cmdline)"
	if [ -d /sys/firmware/acpi/tables ]; then
		echo "tables dir: present ($(ls -1 /sys/firmware/acpi/tables | wc -l) entries)"
	else
		echo "tables dir: ABSENT -- this boot does not have ACPI after all"
	fi
	# the proper tool; -b writes one binary blob, the plain dump is readable text
	acpidump -b -o "$OUT/tables-$(date +%Y%m%d-%H%M%S).bin" 2>&1
	echo "acpidump -b rc=$?"
	acpidump > "$OUT/acpi.txt" 2>&1
	echo "acpidump text rc=$? size=$(stat -c%s "$OUT/acpi.txt" 2>/dev/null || echo 0)"
	# belt and braces: the raw tables too, each size verified, since a previous attempt
	# produced a directory full of zero-byte files and nobody noticed for days
	if [ -d /sys/firmware/acpi/tables ]; then
		mkdir -p "$OUT/tables"
		for t in /sys/firmware/acpi/tables/*; do
			[ -f "$t" ] || continue
			n="$OUT/tables/$(basename $t)"
			cat "$t" > "$n" 2>>"$LOG"
			sz=$(stat -c%s "$n" 2>/dev/null || echo 0)
			[ "$sz" -gt 0 ] || echo "  !! $(basename $t) came out 0 bytes" >> "$LOG"
		done
		echo "raw tables: $(ls -1 "$OUT/tables" | wc -l) files, $(find "$OUT/tables" -type f -size +0 | wc -l) non-empty"
	fi
	echo "acpi.txt size: $(stat -c%s "$OUT/acpi.txt" 2>/dev/null || echo 0)"
	echo "=== done, rebooting ==="
} >> "$LOG" 2>&1
sync
HELP
chmod 755 "$HELPER"
cat > "$UNIT" <<'UNITFILE'
[Unit]
Description=A16: dump the ACPI tables, then reboot
ConditionKernelCommandLine=acpi.harvest=1
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/a16-acpi-harvest.sh
ExecStartPost=/bin/systemctl --no-block reboot

[Install]
WantedBy=multi-user.target
UNITFILE
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable a16-acpi-harvest.service 2>&1 | sed 's/^/  enable: /'
systemctl is-enabled a16-acpi-harvest.service | sed 's/^/  is-enabled: /'
echo
echo "done.  Menus backed up in $ARCH"
echo "Helper: $HELPER (log: $OUTDIR/harvest.log)"
echo
echo "To harvest: pick '$NEW_TITLE'.  The screen stays black and the keyboard is dead --"
echo "that is this boot's normal state.  It dumps the tables, writes the log, and reboots"
echo "by itself (about a minute).  Then boot normally and the tables are in $OUTDIR."
