#!/bin/bash
# a16-acpi-entry.sh -- add ONE extra menu entry that boots the current t2 kernel with ACPI
# left ON and no device tree, so the log collector can copy this machine's ACPI tables out.
#
#   run:  sudo bash ~/a16-payload/camera/a16-acpi-entry.sh
#         sudo bash ~/a16-payload/camera/a16-acpi-entry.sh --remove
#
# Why a separate entry: every normal entry passes acpi=off, and those are exactly the boots
# where /sys/firmware/acpi/tables does not exist.  The menu's own [0] entry used to serve
# this purpose but it boots a staged 7.2 kernel against today's rootfs and no longer comes up.
# This one uses the kernel and initramfs that are known to boot here, so only the display
# side should suffer -- and the collector runs either way, as root, and writes locally.
#
# It touches nothing the normal entries use: one menuentry and a backup beside the file.

set -u
TITLE='A16: ACPI dump (t2 kernel, ACPI on, no device tree)'
KVER=7.3.0-rc5-next-20261002-t2
ROOT_UUID=f8e005e9-414c-4c8e-ad68-d1e9fdc208bc
MENU=/boot/efi/EFI/ubuntu/grub.cfg
CHECK=0
REMOVE=0
for a in "$@"; do
	case "$a" in
		--check)  CHECK=1 ;;
		--remove) REMOVE=1 ;;
		*) echo "usage: $0 [--check|--remove]"; exit 2 ;;
	esac
done

echo "=== a16-acpi-entry: one extra entry for the ACPI dump ==="
[ "$(id -u)" = 0 ] || { echo "  [fail] run me with sudo: $MENU is root-owned on the ESP"; exit 1; }
[ -f "$MENU" ] || { echo "  [fail] $MENU not found"; exit 1; }
[ "$(uname -r)" = "$KVER" ] || echo "  [warn] running kernel is $(uname -r), this entry will use $KVER"

if [ "$REMOVE" = 1 ]; then
	cp -f "$MENU" "$MENU.bak-$(date +%Y%m%d-%H%M%S)"
	python3 - "$MENU" "$TITLE" <<'PY'
import sys
p,t=sys.argv[1],sys.argv[2]
s=open(p).read()
i=s.find('menuentry "%s"'%t)
if i<0: print("  [--] no such entry"); raise SystemExit
j=s.find('\n}\n', i)
s=s[:i-1]+s[j+3:] if j>0 else s
open(p,'w').write(s)
print("  [ok] entry removed")
PY
	echo "  done (backup beside $MENU)"; exit 0
fi

cur=$(grep -c "menuentry \"$TITLE\"" "$MENU" 2>/dev/null)
if [ "$cur" = 1 ]; then echo "  [ok] the entry is already there"; [ "$CHECK" = 1 ] || exit 0; fi
if [ "$CHECK" = 1 ]; then echo "  [check] would add the entry (present: $cur)"; exit 0; fi

cp -f "$MENU" "$MENU.bak-$(date +%Y%m%d-%H%M%S)" || { echo "  [fail] cannot back up $MENU"; exit 1; }
cat >> "$MENU" <<EOF

# ---- added by a16-acpi-entry.sh $(date +%Y%m%d-%H%M%S) ----
# Boots with ACPI ON (no acpi=off) and no device tree, so /sys/firmware/acpi/tables exists
# and the collector can copy the tables.  No display is expected; nothing needs typing.
menuentry "$TITLE" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    if [ -f /boot/vmlinuz-$KVER -a -f /boot/initrd.img-$KVER ]; then
        insmod gzio
        linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro console=tty0 keep_bootcon loglevel=7 systemd.unit=multi-user.target
        initrd /boot/initrd.img-$KVER
        boot
    fi
    echo "  vmlinuz-$KVER or its initramfs is missing"
    sleep 20
    configfile \$prefix/grub.cfg
}
EOF
n=$(grep -c "menuentry \"$TITLE\"" "$MENU")
if [ "$n" = 1 ]; then
	echo "  [ok] entry added: $TITLE"
	echo "       reboot, pick it, wait ~90s, then power-cycle back to your usual entry"
	echo "       (the collector runs as root and writes the tables into ~/a16-payload/camera/acpi/)"
else
	echo "  [fail] the entry did not land cleanly -- restoring the backup"
	cp -f "$(ls -t "$MENU".bak-* | head -1)" "$MENU"
	exit 1
fi
