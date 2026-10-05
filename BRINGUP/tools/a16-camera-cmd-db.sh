#!/usr/bin/env bash
# a16-camera-cmd-db.sh -- write down what this machine's firmware command DB actually
# provides, so the camera's rails can be named correctly.
#
#     sudo bash ~/a16-payload/camera/a16-camera-cmd-db.sh
#
# WHY
#   The RPMh regulator driver does not carry rail addresses in a table: it asks the
#   firmware's command DB, by name, at probe time --
#
#       vreg->addr = cmd_db_read_addr(rpmh_resource_name);
#       if (!vreg->addr) dev_err(dev, "%pOFn: could not find RPMh address for resource %s\n", ...)
#
#   The name is built from the resource type letter, the rail's index and the PMIC id
#   from the device tree, e.g. LDO 4 of pmic-id I_E0 -> "L4I_E0".  Camera boot 63a2221c
#   on 2026-10-05 says exactly this:
#
#       regulators-5: ldo4: could not find RPMh address for resource L4I_E0
#
#   So the module now loads and the rail is described correctly, but this firmware has
#   no "L4I_E0" resource to vote on.  Which keys it does have is the missing fact --
#   inventing an address would write to whatever rail really owns it.
#
# WHAT IT WRITES
#   ~/a16-payload/camera/logs/cmd-db-<timestamp>.txt -- the whole dump, plus the lines
#   for the instances this board's device tree names (B, C, F, I) and the three keys
#   the camera rails would be looked up under (/sys/kernel/debug/cmd-db is 0400 root).
set -eu

out=/home/jc/a16-payload/camera
logdir=$out/logs
dbg=/sys/kernel/debug/cmd-db
stamp=$(date +%Y%m%d-%H%M%S)
log=$logdir/cmd-db-$stamp.txt

[ "$(id -u)" = 0 ] || { printf '  [fail] run me with sudo\n' >&2; exit 1; }
mkdir -p "$logdir"

if [ ! -r "$dbg" ]; then
	printf '  [fail] %s is not readable -- is the cmd-db driver loaded?\n' "$dbg" >&2
	printf '         try: ls /sys/kernel/debug | grep -i cmd\n' >&2
	exit 1
fi

exec > >(tee "$log") 2>&1
echo "=== the firmware command DB, as this machine has it ==="
echo "  source : $dbg"
echo "  written: $log"
echo

# the three keys the camera's rails would be looked up under, with the PMIC ids this
# board's device tree actually uses
echo "--- the camera's rails, by the key the driver would build ---"
for key in L3I_E0 L4I_E0 L7I_E0 S1I_E0 S2I_E0 S3I_E0 S4I_E0 B1I_E0; do
	if grep -qiw "$key" "$dbg" 2>/dev/null; then
		printf '  [ok]   %-8s present: %s\n' "$key" "$(grep -iw "$key" "$dbg" | head -1 | tr -s ' ')"
	else
		printf '  [--]   %-8s NOT in the command DB\n' "$key"
	fi
done

echo
echo "--- every resource the DB has with an I instance (any type) ---"
grep -aoE '[A-Za-z0-9]+I_E[01]' "$dbg" 2>/dev/null | sort -u | tr '\n' ' ' | fold -w 100 | sed 's/^/  /'
echo
echo "--- the same for the instances this board uses, for comparison ---"
for id in B_E0 C_E0 C_E1 F_E0 F_E1; do
	printf '  %-6s %s\n' "$id" "$(grep -aoE "[A-Za-z0-9]+${id%%_*}_${id##*_}" "$dbg" 2>/dev/null | sort -u | tr '\n' ' ')"
done

echo
echo "--- the whole dump (also in the log file) ---"
cat "$dbg"
echo
echo "=== end ==="
echo "Send /home/jc/a16-payload/camera/logs/cmd-db-$stamp.txt back and the device tree can"
echo "be pointed at the rail this firmware really has."
