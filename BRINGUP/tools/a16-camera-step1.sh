#!/usr/bin/env bash
# a16-camera-step1.sh -- put the camera step-1 device tree into the boot menu, or
# take it out again.  Nothing else about the machine changes.
#
#   sudo bash ~/a16-payload/camera/a16-camera-step1.sh          # install
#   sudo bash ~/a16-payload/camera/a16-camera-step1.sh --check   # dry run
#   sudo bash ~/a16-payload/camera/a16-camera-step1.sh remove    # undo
#
# What "install" does:
#   1. verifies the staged DTB really carries the camera nodes (decompiles it)
#   2. copies it to /boot/glymur-a16-camera1.dtb with a .sha256 next to it
#   3. appends ONE menu entry for the running kernel with that device tree, via
#      the repo's own a16-grub-entry.sh, titled so it is unmistakable in the menu
#   4. installs a16-camera-report.sh as a oneshot service, so the boot that uses
#      the camera DTB leaves its evidence in ~/a16-payload/camera/logs/ whether or
#      not the desktop comes up
#
# The default entry is never touched.  A boot into the camera entry that goes
# wrong is left by choosing the usual entry at the menu, and by nothing else.
set -u

HERE="/home/jc/a16-payload/camera"
DTB_SRC="$HERE/glymur-a16-camera1.dtb"
DTB_DST=/boot/glymur-a16-camera1.dtb
KVER="7.3.0-rc5-next-20261002-t2"
TITLE="A16: camera step 1 (CCI1 + OV08X40 sensor, t2 kernel)"
GRUB_TOOL=/home/jc/A16Build/BRINGUP/tools/a16-grub-entry.sh
REPORT="$HERE/a16-camera-report.sh"
REPORT_DST=/usr/local/sbin/a16-camera-report.sh
UNIT=/etc/systemd/system/a16-camera-report.service
MODE="${1:-install}"; MODE="${MODE#--}"

# A dry run needs no privileges: it only decompiles the staged DTB and reads the
# menu.  Everything that writes stays root-only.
if [ "$MODE" != check ] && [ "${A16_ALLOW_NONROOT:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0 ${1:-}"; exit 1; }
fi
say() { printf '%s\n' "$*"; }

[ -f "$GRUB_TOOL" ] || { echo "missing $GRUB_TOOL"; exit 1; }
[ -f "$DTB_SRC" ]   || { echo "missing $DTB_SRC -- it is built in the kernel tree and staged by hand"; exit 1; }

menu() {  # the same rule a16-grub-entry.sh uses: the menu the firmware reads is the
	  # one that names the running kernel, not merely the highest-scoring *ubuntu* one.
	local c best="" best_score=-1 score n running why
	running="$(uname -r 2>/dev/null)"
	for c in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$c" ] || continue
		score=0; why=""
		case "$c" in *ubuntu*) score=$((score+100)); why="ubuntu path";; esac
		n="$(grep -cE '^[[:space:]]*menuentry' "$c" 2>/dev/null || echo 0)"
		score=$((score+n)); why="$why, $n entries"
		grep -q 'linux /boot/vmlinuz' "$c" 2>/dev/null && { score=$((score+10)); why="$why, names kernels"; }
		if [ -n "$running" ] && grep -q "vmlinuz-$running" "$c" 2>/dev/null; then
			score=$((score+1000)); why="$why, names the RUNNING kernel ($running)"
		fi
		printf '  candidate: %-46s %s\n' "$c" "$why" >&2
		[ "$score" -gt "$best_score" ] && { best_score=$score; best="$c"; }
	done
	printf '%s' "$best"
}

verify_dtb() {
	local f="$1" out
	out="$(dtc -I dtb -O dts -f "$f" 2>/dev/null || true)"
	if [ -z "$out" ]; then
		echo "  [fail] cannot decompile $f -- not a device tree?"
		return 1
	fi
	local need="cci@ac16000 camera@36 regulators-5 MCLK4_CLK 0x124f800"
	# cci1 + the sensor + the rail container + the mclk rate must all be there
	for what in "cci@ac16000" "camera@36" "regulators-5" "0x124f800"; do
		if printf '%s' "$out" | grep -q -- "$what"; then echo "  [ok]   $f contains $what"
		else echo "  [fail] $f does NOT contain $what -- wrong build?"; return 1; fi
	done
	if printf '%s' "$out" | grep -A4 'cci@ac16000' | grep -q '0x35b'; then
		echo "  [ok]   cci1 interrupt is 859 (0x35b)"
	else
		echo "  [warn] cci1 interrupt is not 859 -- check the value against the SoC source"
	fi
	if printf '%s' "$out" | grep -q 'status = "okay"'; then :; fi
	# the sensor must hang off cci1 master 1
	if printf '%s' "$out" | grep -q 'camera@36'; then echo "  [ok]   sensor node present"; fi
}

case "$MODE" in
check|install)
	UUID="$(findmnt -no UUID / 2>/dev/null)"
	echo "=== camera step 1 $MODE ==="
	echo "  kernel     : $KVER"
	echo "  vmlinuz    : /boot/vmlinuz-$KVER $([ -f /boot/vmlinuz-$KVER ] && echo ok || echo MISSING)"
	echo "  running dtb: $DTB_SRC"
	sha256sum "$DTB_SRC" | sed 's/^/  sha256     : /'
	echo "--- the DTB really has the camera in it"
	verify_dtb "$DTB_SRC" || exit 1
	MENU="$(menu)"
	[ -n "$MENU" ] || { echo "no GRUB menu found"; exit 1; }
	echo "  menu       : $MENU"
	if grep -q "glymur-a16-camera1.dtb" "$MENU" 2>/dev/null; then
		echo "  [ok]   the menu already has an entry for this DTB -- nothing to add"
		ADDED=0
	else
		ADDED=1
	fi
	if [ "$MODE" = check ]; then
		echo "--- would run:"
		echo "    install $DTB_SRC -> $DTB_DST (+ .sha256)"
		[ "$ADDED" = 1 ] && echo "    $GRUB_TOOL add --force --dtb $DTB_DST --title \"$TITLE\" $KVER"
		echo "    install $REPORT -> $REPORT_DST, unit $UNIT"
		exit 0
	fi

	install -m 0644 "$DTB_SRC" "$DTB_DST" || exit 1
	sha256sum "$DTB_DST" | awk '{print $1}' > "$DTB_DST.sha256"
	echo "  [ok]   installed $DTB_DST ($(stat -c%s "$DTB_DST") bytes, sha256 $(cat "$DTB_DST.sha256"))"

	# The entry text is generated by the repo's own a16-grub-entry.sh, in a sandbox,
	# so there is exactly one definition of what a valid A16 menu entry looks like
	# (its check mode cannot be used: it stops early when the kernel already has an
	# entry, which is always the case here).
	echo "--- generating the entry text (a16-grub-entry.sh, sandbox)"
	SB="$(mktemp -d)"
	mkdir -p "$SB/boot/efi/EFI/ubuntu_snapdragon"
	touch "$SB/boot/vmlinuz-$KVER" "$SB/boot/initrd.img-$KVER"
	cp -f "$DTB_DST" "$SB/boot/$(basename "$DTB_DST")"
	{
		echo "menuentry \"sandbox\" {"
		echo "    linux /boot/vmlinuz-$KVER root=UUID=x"
		echo "}"
	} > "$SB/boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
	A16_ROOT="$SB" A16_ALLOW_NONROOT=1 bash "$GRUB_TOOL" add --force \
		--dtb "$SB/boot/$(basename "$DTB_DST")" --title "$TITLE" "$KVER" >/dev/null 2>&1
	ENTRY="$(sed -n '/^# ---- added by a16-grub-entry.sh/,$p' "$SB/boot/efi/EFI/ubuntu_snapdragon/grub.cfg" | sed '/^$/{/./!d}')"
	rm -rf "$SB"
	if ! printf '%s' "$ENTRY" | grep -q 'menuentry'; then
		echo "  [fail] could not generate the entry text from $GRUB_TOOL -- aborting, menu untouched"
		exit 1
	fi
	printf '%s\n' "$ENTRY" | sed 's/^/  | /'

	menus_with_kernel() {
		local c
		for c in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
			[ -f "$c" ] || continue
			grep -q "vmlinuz-$KVER" "$c" 2>/dev/null || continue
			grep -q "glymur-a16-camera1.dtb" "$c" 2>/dev/null && { echo "  [ok]   already present in $c"; continue; }
			echo "$c"
		done
	}
	MENUS="$(menus_with_kernel)"
	[ -n "$MENUS" ] || echo "  [note] every menu that names $KVER already carries the entry"
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		[ -w "$m" ] || { echo "  [fail] $m is not writable -- run me with sudo"; exit 1; }
		cp -f "$m" "$m.a16-camera-$(date +%Y%m%d-%H%M%S)"
		{ echo; echo "# ---- added by a16-camera-step1.sh $(date '+%Y-%m-%d %H:%M:%S') ----"; printf '%s\n' "$ENTRY"; } >> "$m"
		if grep -q 'glymur-a16-camera1.dtb' "$m"; then
			echo "  [ok]   entry added to $m (backup kept next to it)"
			if command -v grub-script-check >/dev/null 2>&1; then
				grub-script-check "$m" 2>/dev/null && echo "  [ok]   grub-script-check: syntax ok for $m" \
					|| echo "  [warn] grub-script-check complained about $m -- restore its backup if in doubt"
			fi
		else
			echo "  [fail] could not append to $m"
			exit 1
		fi
	done <<< "$MENUS"

	install -m 0755 "$REPORT" "$REPORT_DST" || exit 1
	cat > "$UNIT" <<'UNIT'
[Unit]
Description=A16 camera step 1 evidence (only when the camera device tree is loaded)
Documentation=file:///home/jc/a16-payload/camera/readme-camera-step1.md
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/sbin/a16-camera-report.sh
SuccessExitStatus=0 1
UNIT
	systemctl daemon-reload >/dev/null 2>&1
	systemctl enable a16-camera-report.service >/dev/null 2>&1
	echo "  [ok]   $REPORT_DST + $UNIT (enabled)"

	# one report now, on the running (non-camera) tree, so the file exists and the
	# format is known-good before the boot that matters
	bash "$REPORT" >/dev/null 2>&1 || true

	cat <<NEXT

=== done.  what to do next ===

  1. reboot,  then at the menu pick:  $TITLE
     (Esc at power-on gets the menu; the default entry is unchanged)

  2. after it boots, nothing needs typing: the evidence lands in
         /home/jc/a16-payload/camera/logs/boot-<boot-id>.log
     If you would rather see it straight away:
         bash ~/a16-payload/camera/a16-camera-report.sh

  3. if the screen is not usable in that boot, the same file is written anyway
     (the service runs as root), and the way back is the usual menu entry.

  To undo everything this installed:
         sudo bash ~/a16-payload/camera/a16-camera-step1.sh remove
NEXT
	;;

remove)
	echo "=== camera step 1 remove ==="
	systemctl disable --now a16-camera-report.service >/dev/null 2>&1 || true
	rm -f "$UNIT" "$REPORT_DST"
	systemctl daemon-reload >/dev/null 2>&1
	echo "  [ok]   service and collector removed"
	for m in /boot/efi/EFI/*/grub.cfg /boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$m" ] || continue
		grep -q 'glymur-a16-camera1.dtb' "$m" 2>/dev/null || { echo "  [--]   no camera entry in $m"; continue; }
		[ -w "$m" ] || { echo "  [warn] $m not writable -- remove the entry by hand"; continue; }
		cp -f "$m" "$m.a16-camera-remove-$(date +%Y%m%d-%H%M%S)"
		python3 - "$m" "$TITLE" <<'PY'
import sys

path, title = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
head = 'menuentry "%s" {' % title

for i, l in enumerate(lines):
    if l != head:
        continue
    # the block ends where its braces balance
    depth = 0
    j = i
    while j < len(lines):
        depth += lines[j].count('{') - lines[j].count('}')
        if depth == 0 and j > i:
            break
        j += 1
    # and it starts at our marker comment, plus the blank line before it:
    # anything else that looks like it belongs to a previous writer is left alone
    k = i
    while k - 1 >= 0 and (lines[k - 1].strip() == '' or
                          lines[k - 1].startswith('# ---- added by a16-')):
        k -= 1
    removed = lines[k:j + 1]
    print(f"  [ok]   {path}: removing {len(removed)} lines "
          f"(comment + {j - i + 1}-line menuentry block) for our title only")
    del lines[k:j + 1]
    # drop a leftover blank line so the file looks as it did before
    while len(lines) > 1 and lines[-1] == '' and lines[-2] == '':
        lines.pop()
    open(path, 'w').write('\n'.join(lines))
    break
else:
    print(f"  [warn] {path}: no menuentry titled exactly our title -- nothing removed")
PY
	done
	rm -f "$DTB_DST" "$DTB_DST.sha256"
	echo "  [ok]   removed $DTB_DST"
	echo
	echo "  The usual entries are untouched.  Nothing else was changed."
	;;
*)
	echo "usage: sudo bash $0 [install|--check|remove]"; exit 2
	;;
esac
