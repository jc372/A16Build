#!/bin/bash
# a16-finish-boot.sh — finish the bootloader step that curtin's `curthooks`
# died on during the 2026-09-16 Ubuntu 26.10 install attempt.
#
# Why: curtin's install-grub ran `efibootmgr -v` inside the target chroot and it
# exited 2 with "EFI variables are not supported on this system." -> the whole
# install aborted right before writing anything to the ESP, so the machine has
# no Linux payload and no firmware boot entry.
#
# Run this from a stock Ubuntu live session (the same stonking-desktop-arm64
# daily, which has working input on this machine):
#
#     sudo mount /dev/nvme0n1p12 /mnt
#     sudo bash /mnt/A16FIX.SH
#
# It mounts the installed root read-only first, prints what it finds, then
# installs GRUB with --no-nvram --removable (no efibootmgr needed), generates
# /boot/grub/grub.cfg, tries efibootmgr only if EFI variables actually work, and
# leaves its log at the ESP root as A16BOOT.LOG.
#
# It writes only to: the ESP (\EFI\ubuntu, \EFI\BOOT\BOOTAA64.EFI) and the
# installed root (/boot/grub/grub.cfg, and an initramfs only if one is missing).
# No partitions are touched. No set -e: every step is reported, nothing aborts
# the run.

LOG=/tmp/a16-finish-boot.log
# mirror everything to the console and the log file
exec > >(tee "$LOG") 2>&1

DISK=/dev/nvme0n1
ESPDEV=${DISK}p12
ESP=/mnt/a16esp
ROOT=/mnt/a16root
ROOTDEV=""

say() { echo; echo "=== $* ==="; }

say "a16-finish-boot $(date)  (live session $(uname -r))"
echo "cmdline: $(cat /proc/cmdline)"

say "1. block devices"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME,MOUNTPOINT $DISK
echo
blkid

say "2. EFI runtime / variables (this is what killed the installer)"
ls -l /sys/firmware/efi/ 2>&1
if [ -d /sys/firmware/efi/efivars ]; then
  echo "efivars dir present, $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l) variables visible"
else
  echo "NO /sys/firmware/efi/efivars -- trying to mount efivarfs"
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>&1 || echo "  mount efivarfs FAILED (firmware gives Linux no EFI variable support)"
fi
echo "--- efibootmgr -v ---"
efibootmgr -v; echo "efibootmgr exit=$?"

say "3. looking for the installed Ubuntu root"
for p in $(lsblk -lnpo NAME,FSTYPE $DISK | awk '$2 ~ /ext4|xfs|btrfs/ {print $1}'); do
  echo "--- $p ($(lsblk -lnpo FSTYPE,LABEL $p | head -1)) ---"
  mkdir -p $ROOT
  if mount -o ro "$p" $ROOT 2>/dev/null; then
    sed -n '1,6p' $ROOT/etc/os-release 2>/dev/null || echo "  (no /etc/os-release)"
    echo "  /boot:"; ls -l $ROOT/boot 2>/dev/null | head -20
    echo "  fstab: $([ -f $ROOT/etc/fstab ] && echo present || echo MISSING)"
    echo "  grub.cfg: $([ -f $ROOT/boot/grub/grub.cfg ] && echo present || echo MISSING)"
    if [ -z "$ROOTDEV" ] && [ -f $ROOT/etc/os-release ] && grep -q '^ID=ubuntu' $ROOT/etc/os-release; then
      ROOTDEV=$p; echo "  => using $p as the installed root"
    fi
    umount $ROOT
  else
    echo "  (mount failed)"
  fi
done
if [ -z "$ROOTDEV" ]; then
  echo "!! no Ubuntu root found; stopping so nothing is written"
  say "done"; cp -f "$LOG" /mnt/A16BOOT.LOG 2>/dev/null; exit 1
fi

say "4. mounting root rw + ESP"
mount "$ROOTDEV" $ROOT || { echo "!! cannot mount $ROOTDEV rw"; exit 1; }
mkdir -p $ESP && mountpoint -q $ESP || { mkdir -p $ESP; mount $ESPDEV $ESP || { echo "!! cannot mount ESP $ESPDEV"; exit 1; }; }
mkdir -p $ROOT/boot/efi && mountpoint -q $ROOT/boot/efi || mount $ESPDEV $ROOT/boot/efi
echo "ESP free space:"; df -h $ESP
for d in dev proc sys run; do mount --bind /$d $ROOT/$d 2>/dev/null || echo "  bind /$d failed"; done

say "5. kernel/initramfs sanity check (is the install complete enough to boot?)"
ls -l $ROOT/boot/vmlinuz* $ROOT/boot/initrd* 2>&1

say "6. grub-install (inside the target chroot) --no-nvram, both layouts"
# Normal layout -> \EFI\ubuntu\ (shimaa64.efi + grubaa64.efi + grub.cfg), which is
# what a bcdedit/BIOS boot entry points at.
chroot $ROOT grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --bootloader-id=ubuntu --no-nvram --recheck 2>&1
echo "grub-install (EFI/ubuntu) exit=$?"
# Removable fallback -> \EFI\BOOT\BOOTAA64.EFI, which the firmware finds without
# any NVRAM entry at all.
chroot $ROOT grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --no-nvram --removable --recheck 2>&1
echo "grub-install (removable) exit=$?"
ls -l $ESP/EFI/ubuntu/ $ESP/EFI/BOOT/ 2>&1

say "7. update-grub / initramfs"
if ! ls $ROOT/boot/initrd.img-* >/dev/null 2>&1; then
  echo "no initramfs found -- generating"
  chroot $ROOT update-initramfs -c -k all 2>&1 | tail -20
fi
chroot $ROOT update-grub 2>&1 | tail -30

say "8. fallback: hand-placed payload if grub-install did not deliver one"
if [ ! -f $ESP/EFI/ubuntu/grubaa64.efi ]; then
  echo "no $ESP/EFI/ubuntu/grubaa64.efi -- assembling from the target's own binaries"
  mkdir -p $ESP/EFI/ubuntu $ESP/EFI/BOOT
  for f in /usr/lib/shim/shimaa64.efi.signed /usr/lib/shim/shimaa64.efi; do
    [ -f $ROOT$f ] && { cp -v $ROOT$f $ESP/EFI/ubuntu/shimaa64.efi; break; }
  done
  for f in /usr/lib/grub/arm64-efi/monolithic/grubaa64.efi /usr/lib/grub/arm64-efi/monolithic/grub.efi; do
    [ -f $ROOT$f ] && { cp -v $ROOT$f $ESP/EFI/ubuntu/grubaa64.efi; break; }
  done
  RVID=$(lsblk -lnpo UUID $ROOTDEV | head -1)
  FST=$(lsblk -lnpo FSTYPE $ROOTDEV | head -1)
  KV=$(basename $(ls $ROOT/boot/vmlinuz-* 2>/dev/null | tail -1) 2>/dev/null)
  IV=$(basename $(ls $ROOT/boot/initrd.img-* 2>/dev/null | tail -1) 2>/dev/null)
  case "$FST" in btrfs) FSINS="insmod btrfs" ;; *) FSINS="insmod ext2" ;; esac
  cat > $ESP/EFI/ubuntu/grub.cfg <<EOF
set timeout=5
menuentry "Ubuntu (installed on $ROOTDEV, $FST)" {
    insmod part_gpt
    $FSINS
    search --no-floppy --fs-uuid --set=root $RVID
    linux /boot/$KV root=UUID=$RVID ro quiet splash
    initrd /boot/$IV
}
EOF
  echo "wrote self-contained $ESP/EFI/ubuntu/grub.cfg (kernel=$KV root=$ROOTDEV uuid=$RVID fstype=$FST)"
fi
# also make the removable fallback path point at our grub if the ESP has none
if [ ! -f $ESP/EFI/BOOT/BOOTAA64.EFI ] && [ -f $ESP/EFI/ubuntu/shimaa64.efi ]; then
  cp -v $ESP/EFI/ubuntu/shimaa64.efi $ESP/EFI/BOOT/BOOTAA64.EFI
fi

say "9. try a firmware boot entry (only works if EFI variables are real)"
if [ -d /sys/firmware/efi/efivars ]; then
  efibootmgr -c -d $DISK -p 12 -L Ubuntu -l '\EFI\ubuntu\grubaa64.efi' 2>&1
  efibootmgr -v 2>&1 | head -20
else
  echo "skipped: no EFI variables in this session. Add the entry from Windows:"
  echo "  bcdedit /set {fwbootmgr} displayorder {6a51310e-5b09-11f1-92ef-be9cacaee250} /addfirst"
  echo "  bcdedit /set {6a51310e-5b09-11f1-92ef-be9cacaee250} path \\EFI\\ubuntu\\grubaa64.efi"
  echo "  ...or from the firmware setup: Add New Boot Option -> \\EFI\\ubuntu\\grubaa64.efi"
fi

say "10. what is on the ESP now"
ls -lR $ESP/EFI 2>&1 | head -40
echo "--- $ESP/EFI/ubuntu/grub.cfg ---"; cat $ESP/EFI/ubuntu/grub.cfg 2>&1

say "11. log"
cp -f "$LOG" $ESP/A16BOOT.LOG && echo "log written to the ESP as EFI\\..\\A16BOOT.LOG (filesystem root of the ESP)"
sed -n '1,40p' "$LOG"

say "12. unmounting"
for d in dev proc sys run; do umount $ROOT/$d 2>/dev/null; done
umount $ROOT/boot/efi 2>/dev/null; umount $ROOT 2>/dev/null; umount $ESP 2>/dev/null
sync
echo "done. Reboot and pick the Linux entry (firmware boot menu, F2/F12)."
