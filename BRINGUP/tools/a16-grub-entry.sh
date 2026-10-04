#!/usr/bin/env bash
# a16-grub-entry.sh -- put a freshly built kernel into the boot menu, or take it out again.
#
#   sudo bash a16-grub-entry.sh add                  # newest A16 kernel in /boot
#   sudo bash a16-grub-entry.sh add 7.3.0-rc5-next-20261002-cam1
#   sudo bash a16-grub-entry.sh add --dtb /boot/glymur-a16-stock-<ver>.dtb <ver>
#   sudo bash a16-grub-entry.sh list                 # what is in the menu, and what it names
#   sudo bash a16-grub-entry.sh check                # dry run: what would change, writes nothing
#   sudo bash a16-grub-entry.sh remove 7.3.0-rc5-next-20261002-cam1
#
# What "add" does, in order:
#   1. resolves the kernel version, /boot/vmlinuz-<ver>, the device tree and the initramfs
#   2. builds the initramfs if that version has none -- an entry without one does nothing
#   3. refuses to add a duplicate: if the menu already names that vmlinuz, it says so and stops
#   4. backs up the menu to grub.cfg.a16-<stamp> and appends one menuentry with this machine's real
#      root UUID already filled in
#   5. checks the result with grub-script-check when it is available, and tells you what to reboot
#      into -- leaving every other entry untouched
#
# Kernel options in the entry are the four that this machine needs; see the header of the entry
# itself for why each one is there. Nothing else in the menu file is modified.
#
# Testing without touching the real menu -- every write goes under $A16_ROOT:
#   A16_ROOT=/tmp/a16sb A16_ALLOW_NONROOT=1 bash a16-grub-entry.sh add <ver>
set -u

R="${A16_ROOT:-}"; [ -n "$R" ] && SANDBOX=1 || SANDBOX=0
ROOT() { printf '%s%s' "$R" "$1"; }
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
ACTION="${1:-list}"; shift 2>/dev/null || true
VER=""; DTB=""; TITLE=""; FORCE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dtb)   DTB="${2:-}"; shift ;;
		--title) TITLE="${2:-}"; shift ;;
		--force) FORCE=1 ;;
		*) [ -z "$VER" ] && VER="$1" ;;
	esac
	shift
done

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }

if [ "$ACTION" != list ] && [ "$ACTION" != check ] && [ "${A16_ALLOW_NONROOT:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] || die "run with sudo: sudo bash $0 $ACTION ${VER:-}"
fi

# ------------------------------------------------------------------ locate the pieces
menufile() {
	local c
	for c in "$R"/boot/efi/EFI/*/grub.cfg "$R"/boot/EFI/EFI/*/grub.cfg "$R"/boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$c" ] && { printf '%s' "$c"; return 0; }
	done
	return 1
}
newest_kernel() {  # newest vmlinuz that looks like an A16 linux-next build
	local f best="" best_t=0 t
	for f in "$(ROOT /boot)"/vmlinuz-*; do
		[ -f "$f" ] || continue
		case "${f##*/}" in *next-*|*-a16*|*glymur*) : ;; *) continue ;; esac
		t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
		if [ "$t" -gt "$best_t" ]; then best_t="$t"; best="${f##*/vmlinuz-}"; fi
	done
	[ -n "$best" ] && printf '%s' "$best"
}
resolve() {
	BOOT="$(ROOT /boot)"
	[ -z "$VER" ] && VER="$(newest_kernel)"
	[ -n "$VER" ] || die "no A16 kernel found in ${BOOT##"$R"} -- pass a version, e.g. add 7.3.0-rc5-next-20261002-ec1"
	VMLINUZ="$BOOT/vmlinuz-$VER"
	INITRD="$BOOT/initrd.img-$VER"
	if [ -z "$DTB" ]; then
		for d in "$BOOT/glymur-a16-$VER.dtb" "$BOOT"/glymur-a16-stock-"$VER".dtb "$BOOT"/glymur-a16-*"$VER"*.dtb; do
			[ -f "$d" ] && DTB="$d" && break
		done
	fi
	[ -z "$TITLE" ] && TITLE="[10] A16: next $VER"
}
entry_text() {
	local uuid="$1"
	echo "menuentry \"$TITLE\" {"
	echo "    # root UUID and device tree are this machine's; the four kernel options are required:"
	echo "    #   acpi=off                  -- the ACPI path is broken under Linux on this model"
	echo "    #   clk/pd/regulator_ignore_unused  -- without these the display never comes up"
	echo "    search --no-floppy --fs-uuid --set=root $uuid"
	echo "    if [ -f /boot/vmlinuz-$VER -a -f /boot/initrd.img-$VER ]; then"
	echo "        insmod fdt"
	echo "        insmod gzio"
	echo "        linux /boot/vmlinuz-$VER root=UUID=$uuid ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7"
	echo "        devicetree /boot/${DTB##*/}"
	echo "        initrd /boot/initrd.img-$VER"
	echo "        boot"
	echo "    fi"
	echo "    echo \"  vmlinuz-$VER or its initramfs is missing -- reinstall it\""
	echo "    sleep 20"
	echo "    configfile \$prefix/grub.cfg"
	echo "}"
}

# ------------------------------------------------------------------ actions
case "$ACTION" in
list)
	MENU="$(menufile)" || die "no GRUB menu found (looked under ${R}/boot/efi and ${R}/boot/EFI)"
	step "menu: ${MENU##"$R"}"
	python3 - "$MENU" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
blocks = re.findall(r'^\s*menuentry\s+"([^"]+)"\s*\{(.*?)^\s*\}', t, re.S | re.M)
print(f"  {len(blocks)} menu entries")
for title, body in blocks:
    k = re.search(r'linux\s+(\S+)', body)
    d = re.search(r'devicetree\s+(\S+)', body)
    print(f"    - {title[:64]}")
    if k: print(f"        kernel : {k.group(1)}")
    if not d: print("        devicetree: (none -- a16 entries need one)")
PY
	;;
check|add)
	resolve
	step "kernel $VER"
	echo "  vmlinuz   : ${VMLINUZ##"$R"}$([ -f "$VMLINUZ" ] || echo '   <-- MISSING')"
	echo "  initramfs : ${INITRD##"$R"}$([ -f "$INITRD" ] || echo '   <-- MISSING')"
	echo "  devicetree: ${DTB:-none found}"
	[ -f "$VMLINUZ" ] || [ "$ACTION" = check ] || die "no ${VMLINUZ##"$R"} -- build or install that kernel first"
	[ -n "$DTB" ] && [ -f "$DTB" ] || [ "$ACTION" = check ] || die "no device tree for $VER -- pass --dtb"
	MENU="$(menufile)" || die "no GRUB menu found (looked under ${R}/boot/efi and ${R}/boot/EFI)"
	UUID="$(findmnt -no UUID / 2>/dev/null || echo '')"
	[ -n "$UUID" ] || [ "$SANDBOX" = 1 ] && UUID="${UUID:-11111111-2222-3333-4444-555555555555}"
	[ -n "$UUID" ] || die "could not read the root filesystem UUID"
	echo "  uuid      : $UUID"
	echo "  menu      : ${MENU##"$R"}"
	if grep -q "vmlinuz-$VER" "$MENU" 2>/dev/null; then
		[ "$FORCE" = 1 ] || { ok "the menu already has an entry naming vmlinuz-$VER -- nothing to do"; exit 0; }
		warn "--force given: adding a second entry for the same kernel"
	fi
	[ "$ACTION" = check ] && { step "would append"; entry_text "$UUID" | sed 's/^/  /'; exit 0; }
	if [ ! -f "$INITRD" ] && [ "$SANDBOX" = 1 ]; then
		warn "sandbox: not building an initramfs (real run would: update-initramfs -c -k $VER)"
	elif [ ! -f "$INITRD" ]; then
		warn "no ${INITRD##"$R"} -- building it, an entry without one cannot boot"
		if [ "$SANDBOX" = 0 ] && command -v update-initramfs >/dev/null 2>&1; then
			update-initramfs -c -k "$VER" || update-initramfs -u -k "$VER" || true
		fi
		[ -f "$INITRD" ] || warn "still missing -- run: sudo update-initramfs -c -k $VER"
	fi
	BAK="$MENU.a16-$STAMP"
	cp -f "$MENU" "$BAK" && ok "menu backed up to ${BAK##"$R"}"
	{ echo; echo "# ---- added by a16-grub-entry.sh $STAMP ----"; entry_text "$UUID"; } >> "$MENU"
	if grep -q "vmlinuz-$VER" "$MENU"; then
		ok "entry added: \"$TITLE\""
		if command -v grub-script-check >/dev/null 2>&1; then
			if grub-script-check "$MENU" 2>/dev/null; then ok "grub-script-check: syntax ok"
			else warn "grub-script-check complained -- restore ${BAK##"$R"} if in doubt"; fi
		fi
		printf '\n  reboot and pick "%s" with Esc at power-on.\n' "$TITLE"
		printf '  the previous entries are untouched -- if the display does not come up, use one.\n'
	else
		warn "could not append the entry; the menu is unchanged apart from the backup"
		exit 1
	fi
	;;
remove)
	resolve
	MENU="$(menufile)" || die "no GRUB menu found"
	grep -q "vmlinuz-$VER" "$MENU" || { ok "no entry for $VER in the menu"; exit 0; }
	BAK="$MENU.a16-$STAMP"
	cp -f "$MENU" "$BAK" && ok "menu backed up to ${BAK##"$R"}"
	python3 - "$MENU" "$VER" <<'PY'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
t = open(path).read()
out, i, removed = [], 0, 0
# walk menuentry blocks by brace depth and drop the ones naming this vmlinuz
for m in re.finditer(r'(?m)^(\s*menuentry\s+"[^"]+"\s*\{)', t):
    start = m.start()
    depth = 0; j = m.start(1) + len(m.group(1)) - 1
    while j < len(t):
        if t[j] == '{': depth += 1
        elif t[j] == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    end = j + 1
    block = t[start:end]
    out.append(t[i:start])
    if f'vmlinuz-{ver}' in block:
        removed += 1
    else:
        out.append(block)
    i = end
out.append(t[i:])
open(path, 'w').write(''.join(out))
print(f"  removed {removed} entr{'y' if removed==1 else 'ies'} naming vmlinuz-{ver}")
PY
	command -v grub-script-check >/dev/null 2>&1 && grub-script-check "$MENU" 2>/dev/null && ok "menu syntax ok" || true
	;;
*)
	die "unknown action '$ACTION' -- use: list | check | add [version] | remove [version]"
	;;
esac
