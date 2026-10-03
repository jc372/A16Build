#!/bin/bash
# a16-stage-esp-boot.sh — stage 2 of the 2026-09-16 bootloader repair.
#
# Run from the stock Ubuntu live session (the daily that boots this machine):
#
#     sudo mount /dev/nvme0n1p12 /mnt
#     sudo bash /mnt/A16STAGE2.SH
#
# Why this exists
# ---------------
# Stage 1 (scripts/a16-finish-boot.sh, staged as \A16FIX.SH) ran and did its own
# job: its log, A16BOOT.LOG on the ESP, shows both grub-install passes exiting 0
# (--bootloader-id=ubuntu and --removable) and update-grub writing a config with
# "Found linux image: /boot/vmlinuz-7.2.0-5-generic".  So the ESP now carries
# the target's signed shim+GRUB and the stub
#
#     search.fs_uuid f8e005e9-414c-4c8e-ad68-d1e9fdc208bc root
#     set prefix=($root)'/boot/grub'
#     configfile $prefix/grub.cfg
#
# and the installed root has a generated /boot/grub/grub.cfg.  The menu on the
# panel is therefore the installed system's own menu — but every entry dies and
# the panel shows GRUB's message from the command *after* the failing one:
#
#     linux  /boot/vmlinuz-7.2.0-5-generic root=UUID=...   <- never loaded
#     initrd /boot/initrd.img-7.2.0-5-generic             <- "you need to load the kernel first"
#
# i.e. GRUB read its config off the ext4 root but would not load the kernel.  Two
# things are missing to explain that: the generated config itself, and whether
# the loader had what it needs (module directory, kernel file format, ext4
# features).  Which is what part 1 collects.
#
# Part 2 sidesteps the whole question: the installed kernel and initrd are copied
# onto the ESP (FAT), the target's GRUB module directory is copied beside them,
# and one config with four entries is written to *every* location a GRUB on this
# ESP is known to read a config from (the embedded prefixes are /EFI/ubuntu for
# the signed binary both firmware entries run, /boot/grub for the --removable
# one, and each binary's own directory).  Whichever entry in the firmware boot
# menu the operator picks, the menu they get has:
#
#   0  installed Ubuntu, kernel + initrd from the ESP  (no ext4 involved)
#   1  installed Ubuntu, its own generated grub.cfg    (normal path, kept working)
#   2  diagnostics: devices, staged payload, root /boot, module checks, prefix
#   3  Windows Boot Manager                            (escape hatch)
#
# Writes only to the ESP (a16boot/, EFI/ubuntu/grub.cfg, EFI/ubuntu_snapdragon/
# grub.cfg, EFI/BOOT/grub.cfg, boot/grub/grub.cfg, A16ESP-BACKUP/, logs) and
# reads the installed root.  Nothing on the NVMe is modified, no partition is
# touched, no set -e: every step is reported and nothing aborts the run.

LOG=/tmp/a16-stage2.log
exec > >(tee "$LOG") 2>&1

DISK=/dev/nvme0n1
ESPDEV=${DISK}p12
ESP=${A16_ESP:-/mnt}          # the operator mounts the ESP here to run this file
ROOTDEV=""
ROOT=/mnt/a16root
say() { echo; echo "=== $* ==="; }

say "a16-stage-esp-boot $(date)  (live session $(uname -r))"
echo "cmdline: $(cat /proc/cmdline)"

say "0. where is the ESP?"
if findmnt -no SOURCE,FSTYPE "$ESP" 2>/dev/null | grep -q "$ESPDEV"; then
  echo "ESP is mounted at $ESP ($(findmnt -no SOURCE,FSTYPE "$ESP"))"
else
  echo "$ESP is not $ESPDEV -- trying $ESPDEV at /mnt/a16esp"
  mkdir -p /mnt/a16esp
  if mount "$ESPDEV" /mnt/a16esp; then ESP=/mnt/a16esp; else
    echo "!! cannot find/mount the ESP; stopping so nothing is written"; exit 1
  fi
fi
[ -f "$ESP/A16STAGE2.SH" ] && echo "found $ESP/A16STAGE2.SH (this script)"
df -h "$ESP"
ls -l "$ESP"

say "1. block devices"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT $DISK
echo; blkid

say "2. locating the installed Ubuntu root"
for p in $(lsblk -lnpo NAME,FSTYPE $DISK | awk '$2 ~ /ext4|xfs|btrfs/ {print $1}'); do
  echo "--- $p ---"
  mkdir -p $ROOT
  if mount -o ro "$p" $ROOT 2>/dev/null; then
    sed -n '1,3p' $ROOT/etc/os-release 2>/dev/null
    if [ -z "$ROOTDEV" ] && grep -q '^ID=ubuntu' $ROOT/etc/os-release 2>/dev/null; then
      ROOTDEV=$p; echo "  => installed Ubuntu root is $p"
    fi
    umount $ROOT
  else
    echo "  (mount failed)"
  fi
done
if [ -z "$ROOTDEV" ]; then
  echo "!! no Ubuntu root found; stopping so nothing is written"
  cp -f "$LOG" "$ESP/A16STAGE2.LOG" 2>/dev/null; exit 1
fi
RVID=$(lsblk -lnpo UUID $ROOTDEV | head -1)
echo "root=$ROOTDEV  uuid=$RVID"
mount "$ROOTDEV" $ROOT || { echo "!! cannot mount $ROOTDEV"; exit 1; }

say "3. diagnostics (everything goes to the ESP as A16DIAG2.TXT)"
D=$ESP/A16DIAG2.TXT
{
  echo "a16 diag, live session $(date -u), $(uname -r)"
  echo "installed root: $ROOTDEV uuid=$RVID"
  echo
  echo "== installed /boot =="
  ls -l $ROOT/boot
  echo
  echo "== kernel file format (MZ = EFI stub PE, 1f8b = gzip, else plain Image) =="
  for f in $ROOT/boot/vmlinuz-*; do
    [ -f "$f" ] || continue
    printf '%-60s %s bytes  first4=' "$f" "$(stat -c%s "$f")"
    od -An -tx1 -N4 "$f" | tr -d ' \n'
    echo
    file -b "$f" 2>/dev/null || echo "  (no file(1) in this session)"
    sha256sum "$f"
  done
  echo
  echo "== initrd =="
  ls -l $ROOT/boot/initrd.img-* 2>/dev/null
  echo
  echo "== installed /boot/grub =="
  ls -l $ROOT/boot/grub
  echo "module count: $(ls $ROOT/boot/grub/arm64-efi 2>/dev/null | wc -l)"
  for m in gzio.mod ext2.mod linux.mod initrd.mod normal.mod fat.mod part_gpt.mod search.mod search_fs_uuid.mod fdt.mod smbios.mod all_video.mod efi_gop.mod; do
    if [ -f "$ROOT/boot/grub/arm64-efi/$m" ]; then echo "  $m: PRESENT"; else echo "  $m: missing"; fi
  done
  echo "grubenv: $(sha256sum $ROOT/boot/grub/grubenv 2>/dev/null || echo none)"
  echo
  echo "== /etc/fstab =="
  cat $ROOT/etc/fstab
  echo
  echo "== /etc/default/grub =="
  cat $ROOT/etc/default/grub
  echo
  echo "== ext4 features of the installed root (metadata_csum_seed / orphan_file matter to GRUB) =="
  tune2fs -l $ROOTDEV 2>&1 | grep -iE 'Filesystem volume|Block size|Filesystem features|Filesystem UUID|Inode size|Filesystem state' 
  echo
  echo "== installed /boot/grub/grub.cfg: first menu entries =="
  grep -n -m40 -E "menuentry|submenu|linux[[:space:]]|initrd[[:space:]]|devicetree|search --|set root|insmod" $ROOT/boot/grub/grub.cfg 2>/dev/null || echo "(cannot read it!)"
  echo
  echo "== kernel packages =="
  ls -l $ROOT/var/lib/dpkg/info/linux-image-*.list 2>/dev/null | head
  grep -h -m1 'Package: linux-image' $ROOT/var/lib/dpkg/status 2>/dev/null | head
  echo
  echo "== GRUB/shim packages (version strings from the installed system) =="
  ls -l $ROOT/usr/lib/grub/arm64-efi/monolithic/ 2>/dev/null
  ls -l $ROOT/usr/lib/grub/arm64-efi/modinfo.sh $ROOT/usr/lib/grub/arm64-efi-signed/ 2>/dev/null
  echo
  echo "== what the ESP carried before this run =="
  for f in EFI/ubuntu/grub.cfg EFI/ubuntu_snapdragon/grub.cfg EFI/BOOT/grub.cfg; do
    [ -f "$ESP/$f" ] && echo "--- $f ($(stat -c%s "$ESP/$f") bytes, sha256 $(sha256sum "$ESP/$f" | cut -c1-16)) ---" && cat "$ESP/$f"
  done
  echo
  echo "== /sys/firmware/efi =="
  ls -l /sys/firmware/efi/ 2>&1
  echo "efivars: $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l) entries"
  command -v efibootmgr || echo "efibootmgr: not installed in this live session"
} > $D 2>&1
echo "wrote $D ($(stat -c%s $D) bytes)"
cp -f $ROOT/boot/grub/grub.cfg $ESP/P17-GRUB.CFG 2>/dev/null && echo "copied the installed grub.cfg to $ESP/P17-GRUB.CFG"

say "4. staging kernel + initrd + GRUB modules onto the ESP"
KV=$(basename "$(ls -1 $ROOT/boot/vmlinuz-* 2>/dev/null | tail -1)")
IV=$(basename "$(ls -1 $ROOT/boot/initrd.img-* 2>/dev/null | tail -1)")
if [ -z "$KV" ] || [ -z "$IV" ]; then echo "!! no kernel/initrd in $ROOT/boot; stopping"; exit 1; fi
echo "kernel=$KV initrd=$IV"
NEED=$(( ($(stat -c%s $ROOT/boot/$KV) + $(stat -c%s $ROOT/boot/$IV)) / 1024 / 1024 + 40 ))
FREE=$(df -Pm "$ESP" | awk 'NR==2 {print $4}')
echo "need about ${NEED} MB, ESP has ${FREE} MB free"
if [ "$FREE" -lt "$NEED" ]; then echo "!! not enough room on the ESP; stopping"; exit 1; fi

mkdir -p $ESP/a16boot
cp -f $ROOT/boot/$KV  $ESP/a16boot/vmlinuz   && echo "copied $KV -> a16boot/vmlinuz"
cp -f $ROOT/boot/$IV  $ESP/a16boot/initrd.img && echo "copied $IV -> a16boot/initrd.img"
if [ -d $ROOT/boot/grub/arm64-efi ]; then
  rm -rf $ESP/a16boot/arm64-efi
  cp -r $ROOT/boot/grub/arm64-efi $ESP/a16boot/arm64-efi && echo "copied $(ls $ESP/a16boot/arm64-efi | wc -l) modules -> a16boot/arm64-efi"
fi
mkdir -p $ESP/EFI/ubuntu/arm64-efi
cp -f $ROOT/boot/grub/arm64-efi/*.mod $ESP/EFI/ubuntu/arm64-efi/ 2>/dev/null && echo "copied modules -> EFI/ubuntu/arm64-efi (for a config read with prefix=/EFI/ubuntu)"

say "5. backups of the existing ESP configs"
mkdir -p $ESP/A16ESP-BACKUP
for f in EFI/ubuntu/grub.cfg EFI/ubuntu_snapdragon/grub.cfg EFI/BOOT/grub.cfg; do
  [ -f "$ESP/$f" ] || continue
  b=$(echo "$f" | tr '/' '_')
  cp -f "$ESP/$f" "$ESP/A16ESP-BACKUP/$b" && echo "backed up $f -> A16ESP-BACKUP/$b"
done

say "6. writing the staged config"
# keep whatever kernel parameters the installed system's own config uses
KPARMS=$(awk '/^[[:space:]]*linux[[:space:]]/ {sub(/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]*/,""); gsub(/root=[^[:space:]]+/,""); print; exit}' $ROOT/boot/grub/grub.cfg 2>/dev/null)
[ -z "$KPARMS" ] && KPARMS="ro quiet splash"
echo "kernel parameters taken from the installed config: '$KPARMS'"

cat > /tmp/a16-stage2-grub.cfg <<EOF
# Staged by a16-stage-esp-boot.sh on $(date -u) from a $(uname -r) live session.
# Entry 0 needs nothing but the ESP: kernel, initrd and the GRUB modules are all
# on this FAT volume.  Entry 1 keeps the installed system's own generated config
# in the path.  Entry 2 prints what a diagnosis needs.  Entry 3 goes back to
# Windows.  The live session that wrote this reported:
#   installed root  = $ROOTDEV  (UUID $RVID)
#   kernel          = $KV
#   initrd          = $IV
set timeout=30
set timeout_style=menu
set default=0

insmod part_gpt
insmod fat
insmod ext2
insmod search_fs_file
insmod sleep

# Snapdragon boards: Ubuntu's own arm64 config cuts a bogus high window out of
# the memory map before handing memory to the kernel.
insmod smbios
insmod regexp
smbios --type 4 --get-string 5 --set proc_version
regexp "Snapdragon.*" "\$proc_version"
if [ "\$?" = "0" ]; then
  if [ "\$lockdown" != "y" ]; then
    cutmem 0x8800000000 0x8fffffffff
  fi
fi

menuentry "A16: installed Ubuntu - kernel and initrd staged on the ESP" {
    echo "  prefix=\$prefix  cmdpath=\$cmdpath"
    search --no-floppy --file --set=a16esp /a16boot/vmlinuz
    if [ -z "\$a16esp" ]; then
        echo "  /a16boot/vmlinuz is not on any device -- staged payload missing"
    else
        echo "  staged payload is on \$a16esp"
        set root=\$a16esp
        set prefix="\$a16esp/a16boot"
        insmod gzio
        linux /a16boot/vmlinuz root=UUID=$RVID $KPARMS
        initrd /a16boot/initrd.img
        boot
    fi
    echo "  entry 0 did not boot"
}

menuentry "A16: installed Ubuntu - its own generated grub.cfg (normal path)" {
    echo "  prefix=\$prefix  cmdpath=\$cmdpath"
    search --no-floppy --fs-uuid --set=root $RVID
    echo "  root=\$root (want UUID $RVID)"
    set prefix="(\$root)/boot/grub"
    configfile \$prefix/grub.cfg
    echo "  could not read (\$root)/boot/grub/grub.cfg"
}

menuentry "A16: diagnostics - photograph this screen" {
    set pager=0
    echo "  === A16 GRUB diagnostics ==="
    echo "  prefix=\$prefix"
    echo "  cmdpath=\$cmdpath"
    echo "  platform=\$grub_platform  cpu=\$grub_cpu"
    search --no-floppy --file --set=a16esp /a16boot/vmlinuz
    echo "  staged payload found on: \$a16esp"
    search --no-floppy --fs-uuid --set=r17 $RVID
    echo "  UUID $RVID -> \$r17"
    echo "  --- staged ESP payload ---"
    ls (\$a16esp)/a16boot
    echo "  --- installed root ---"
    if [ -f (\$r17)/boot/$KV ]; then echo "    /boot/$KV: PRESENT"; else echo "    /boot/$KV: MISSING"; fi
    if [ -f (\$r17)/boot/$IV ]; then echo "    /boot/$IV: PRESENT"; else echo "    /boot/$IV: MISSING"; fi
    for m in gzio.mod ext2.mod linux.mod normal.mod fat.mod part_gpt.mod search.mod fdt.mod; do
        if [ -f (\$r17)/boot/grub/arm64-efi/\$m ]; then echo "    module \$m: PRESENT"; else echo "    module \$m: MISSING"; fi
    done
    ls (\$r17)/boot
    echo "  === end: prefix=\$prefix cmdpath=\$cmdpath esp=\$a16esp root=\$r17 ==="
    echo "  (sleeping 90s - photograph now)"
    sleep 90
}

menuentry "Windows Boot Manager" {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
echo "--- staged config ---"; cat /tmp/a16-stage2-grub.cfg
cp -f /tmp/a16-stage2-grub.cfg $ESP/a16boot/grub.cfg

say "7. placing it where a GRUB on this ESP will find it"
# The signed grubaa64.efi both firmware Linux entries run was built with prefix
# /EFI/ubuntu, the --removable one with /boot/grub; the config can also be read
# from the directory the binary was loaded from.  Cover all of them, plus the
# dir the two firmware entries actually point into.
mkdir -p $ESP/boot/grub
for d in EFI/ubuntu EFI/ubuntu_snapdragon EFI/BOOT boot/grub; do
  cp -f /tmp/a16-stage2-grub.cfg "$ESP/$d/grub.cfg" && echo "wrote $d/grub.cfg ($(stat -c%s "$ESP/$d/grub.cfg") bytes)"
done

say "8. what is on the ESP now"
ls -l $ESP/a16boot $ESP/EFI/ubuntu $ESP/EFI/ubuntu_snapdragon $ESP/EFI/BOOT 2>&1
df -h $ESP

say "9. checks"
for d in a16boot/vmlinuz a16boot/initrd.img a16boot/grub.cfg a16boot/arm64-efi/gzio.mod EFI/ubuntu/grub.cfg EFI/ubuntu_snapdragon/grub.cfg EFI/BOOT/grub.cfg; do
  if [ -f "$ESP/$d" ]; then echo "  OK   $d ($(stat -c%s "$ESP/$d") bytes)"; else echo "  FAIL $d"; fi
done
grep -q "$RVID" $ESP/a16boot/grub.cfg && echo "  OK   staged config carries root=UUID=$RVID" || echo "  FAIL staged config has no root UUID"
sha256sum $ESP/a16boot/vmlinuz $ESP/a16boot/initrd.img

say "10. log"
cp -f "$LOG" "$ESP/A16STAGE2.LOG" && echo "log written to the ESP as A16STAGE2.LOG"
sed -n '1,25p' "$LOG"

say "11. unmounting"
umount $ROOT 2>/dev/null
sync
echo "done."
echo "Reboot: firmware boot menu (F2/F12), pick the Linux entry, then choose"
echo "  'A16: installed Ubuntu - kernel and initrd staged on the ESP'"
echo "If that one fails, pick 'A16: diagnostics ...' and photograph the screen."
