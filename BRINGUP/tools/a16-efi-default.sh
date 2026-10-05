#!/bin/bash
# a16-efi-default.sh -- make both ESP grub menus default to the t2 kernel, and fix the
# camera entry's stale title (it still said OV08X40; the part is an OV02C10).
#
#   run:  sudo bash ~/a16-payload/camera/a16-efi-default.sh
#         sudo bash ~/a16-payload/camera/a16-efi-default.sh --check
#
# It does NOT touch the firmware's own boot order: it prints it, and prints the one line
# that would demote the snapdragon entries, for you to run if you want that.
#
# Every menu file is copied to <file>.bak-<stamp> beside itself before it is touched, and
# each edit is verified by reading the file back.  Nothing here touches the kernel, the
# initramfs or any device tree.

set -u
T2_TITLE='A16: linux-next 7.3.0-rc5-next-20261002-t2'
OLD_TITLE='A16: camera step 1 (CCI1 + OV08X40 sensor, t2 kernel)'
NEW_TITLE='A16: camera step 1 (CCI1 + front sensor, t2 kernel)'
MENUS="/boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
# only this menu's default is set.  The ubuntu menu's 'set default=3' is the operator's
# standing entry and is deliberately left exactly as it is.
DEFAULT_IN="/boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

echo "=== a16-efi-default: the ESP grub menus ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo: the ESP is not writable as $(id -un)"; exit 1; }

echo
echo "--- the firmware's own boot order"
if command -v efibootmgr >/dev/null 2>&1; then
	efibootmgr 2>/dev/null | grep -E '^Boot(Current|Order|0001|0002|0003|0004)' | sed 's/^/  /'
	echo "  (BootCurrent is the entry this boot used; BootOrder is what the firmware tries, in order)"
else
	echo "  [--] no efibootmgr; read the order in the firmware setup screen"
fi

rc=0
for m in $MENUS; do
	echo
	echo "--- $m"
	if [ ! -f "$m" ]; then echo "  [--] not present"; continue; fi

	# what the menu carries and what it defaults to
	t2=$(grep -c "menuentry \"$T2_TITLE\"" "$m" 2>/dev/null)
	cur=$(grep -m1 '^set default' "$m" 2>/dev/null)
	echo "  carries the t2 entry : $([ "$t2" -gt 0 ] && echo yes || echo NO)"
	echo "  current default      : ${cur:-（none set）}"

	if [ "$t2" -eq 0 ]; then
		echo "  [skip] this menu has no t2 entry to default to"
		continue
	fi

	need_default=0
	if [ "$m" = "$DEFAULT_IN" ]; then
		echo "$cur" | grep -qF "$T2_TITLE" || need_default=1
	else
		echo "  [ok] this menu's default is left as it is ($cur)"
	fi
	need_title=0
	grep -qF "$OLD_TITLE" "$m" && need_title=1

	if [ "$CHECK" = 1 ]; then
		echo "  [check] would set the default to t2 : $([ "$need_default" = 1 ] && echo yes || echo 'no, already t2')"
		echo "  [check] would fix the camera title  : $([ "$need_title" = 1 ] && echo yes || echo 'no, already right')"
		continue
	fi

	if [ "$need_default" = 0 ] && [ "$need_title" = 0 ]; then
		echo "  [ok] already defaults to t2 and the camera title is right -- nothing to change"
		continue
	fi

	bak="$m.bak-$(date +%Y%m%d-%H%M%S)"
	cp -f "$m" "$bak" || { echo "  [fail] could not copy the menu to $bak"; rc=1; continue; }
	echo "  saved: $bak"

	if [ "$need_default" = 1 ]; then
		# put the default at the top of the file's variable block, replacing the old one
		sed -i "s|^set default=.*|set default=\"$T2_TITLE\"|" "$m"
		if grep -qF "set default=\"$T2_TITLE\"" "$m"; then
			echo "  [ok] default is now the t2 entry"
		else
			echo "  [fail] the default did not take -- restoring $bak"
			cp -f "$bak" "$m"; rc=1
		fi
	fi

	if [ "$need_title" = 1 ]; then
		sed -i "s|$OLD_TITLE|$NEW_TITLE|g" "$m"
		if grep -qF "$NEW_TITLE" "$m"; then
			echo "  [ok] camera entry title now is neutral"
		else
			echo "  [fail] the title did not change -- it is only a label, leaving the file alone"
		fi
	fi

	echo "  now: $(grep -m1 '^set default' "$m")  /  camera entries: $(grep -c "menuentry \"$NEW_TITLE\"" "$m")"
done

echo
echo "=== if you also want the firmware to try the snapdragon entries last ==="
echo "  currently it tries them before Windows.  To move them behind it:"
echo "      sudo efibootmgr -o 0003,0002,0001,0004"
echo "  (0003 = EFI\\ubuntu, the menu with 'set default=3'; 0002 = Windows; 0001/0004 = the"
echo "   snapdragon shim and grub.  Reversible from the firmware setup screen.)"
echo
[ "$rc" = 0 ] && echo "done." || echo "finished with errors (rc=$rc) -- the backups are beside each menu file."
exit $rc
