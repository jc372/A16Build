#!/bin/sh
# A16 bring-up harvest.
#
# The A16 has no working internal keyboard/touchpad in ACPI mode, so a live
# session cannot be interrogated by hand. This script collects the device,
# firmware and memory facts that decide the next build step, writes them to a
# FAT/ext4 volume the operator can read from Windows, and prints a short
# summary straight to the panel console for a photograph.
#
# Runs from a systemd unit injected into the live root by the ISO builder's
# scripts/local-bottom hook. Must never fail the boot: no `set -e`.
set -u

STAMP="$(date +%Y%m%d-%H%M%S)"
W="/run/a16-harvest"
D="$W/data"
mkdir -p "$D"

# ---------------------------------------------------------------- collection
copy() {  # copy <src> <name>  (never fatal)
  [ -e "$1" ] && cp -a "$1" "$D/$2" 2>/dev/null
  return 0
}

{
  echo "a16-harvest $STAMP"
  echo "== identity =="
  uname -a
  cat /proc/cmdline
  for f in sys_vendor product_name product_family board_name bios_version bios_date; do
    printf '%s: %s\n' "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"
  done
  echo "== fdt =="
  if [ -f /sys/firmware/fdt ]; then
    echo "/sys/firmware/fdt present: $(wc -c < /sys/firmware/fdt) bytes"
  else
    echo "no /sys/firmware/fdt (ACPI boot)"
  fi
  echo "== efi systab =="
  cat /sys/firmware/efi/systab 2>/dev/null || echo none
  echo "== iomem =="
  cat /proc/iomem
  echo "== firmware memmap =="
  cat /sys/firmware/memmap 2>/dev/null || echo none
  echo "== memory =="
  # Ubuntu live images have no /var/log/dmesg, which is why the first hardware
  # harvest reported nothing here: MemTotal is the definitive "how much RAM does
  # Linux actually manage" figure and must come from /proc/meminfo.
  grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|VmallocTotal)' /proc/meminfo 2>/dev/null
  dmesg 2>/dev/null | grep -iE 'Memory:|mem auto-init|reserved memory|cma: reserved|memblock' | head -20
  [ -f /var/log/dmesg ] && grep -E '^Memory:|memmap|reserved' /var/log/dmesg | head -20
  echo "== input devices =="
  cat /proc/bus/input/devices 2>/dev/null || echo none
  echo "== hid =="
  ls -l /sys/bus/hid/devices 2>/dev/null
  echo "== i2c adapters =="
  ls -l /sys/bus/i2c/devices 2>/dev/null || echo none
  echo "== gpio =="
  ls -l /sys/bus/gpio/devices 2>/dev/null || echo none
  echo "== acpi devices =="
  for d in /sys/bus/acpi/devices/*; do
    [ -e "$d/hid" ] || continue
    printf '%s uid=%s status=%s class=%s\n' \
      "$(cat "$d/hid" 2>/dev/null)" "$(cat "$d/uid" 2>/dev/null)" \
      "$(cat "$d/status" 2>/dev/null)" "$(cat "$d/real_power_state" 2>/dev/null)"
  done
  echo "== platform devices =="
  ls /sys/bus/platform/devices 2>/dev/null
  echo "== usb =="
  ls /sys/bus/usb/devices 2>/dev/null
  echo "== drm =="
  ls -l /sys/class/drm 2>/dev/null
  echo "== modules (a16 relevant) =="
  cat /proc/modules | grep -Ei 'i2c|hid|pinctrl|geni|msm|panel|ath' || echo none
  echo "== modinfo =="
  for m in i2c_hid_acpi i2c_hid hid_multitouch i2c_qcom_geni pinctrl_glymur qcom_geni_se; do
    printf '%-16s %s\n' "$m" "$(modinfo -n "$m" 2>&1 | head -1)"
  done
  echo "== block =="
  cat /proc/partitions
  echo "== interrupts =="
  cat /proc/interrupts
} > "$D/summary.txt" 2>&1

copy /sys/firmware/acpi/tables acpi-tables
copy /sys/firmware/efi/systab efi-systab
copy /proc/iomem iomem.txt
copy /proc/meminfo meminfo.txt
copy /proc/bus/input/devices input-devices.txt
copy /proc/interrupts interrupts.txt
[ -f /sys/firmware/fdt ] && copy /sys/firmware/fdt firmware.dtb
dmesg > "$D/dmesg.txt" 2>/dev/null || true
lsmod > "$D/lsmod.txt" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTUUID > "$D/lsblk.txt" 2>/dev/null || true
blkid > "$D/blkid.txt" 2>/dev/null || true
{
  echo "== /sys/firmware/efi/efivars =="
  if [ -d /sys/firmware/efi/efivars ]; then
    echo "present: $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l) variables visible"
    ls /sys/firmware/efi/efivars 2>/dev/null | head -25
  else
    echo "ABSENT: /sys/firmware/efi/efivars does not exist -> efibootmgr cannot work"
  fi
  echo "== mount | grep efivar =="
  mount | grep -i efivar || echo "(no efivarfs mount)"
  echo "== efibootmgr -v (stdout+stderr, with exit code) =="
  efibootmgr -v 2>&1
  echo "efibootmgr exit=$?"
} > "$D/efibootmgr.txt" 2>&1
cp /proc/cmdline "$D/cmdline.txt" 2>/dev/null || true

# ------------------------------------------------------------ console summary
SINK_DESC="none (console summary only)"
{
  echo ""
  echo "================ A16 HARVEST ================"
  echo "stamp   : $STAMP"
  echo "kernel  : $(uname -r)"
  echo "cmdline : $(tr -s ' ' < /proc/cmdline | cut -c1-160)"
  echo "product : $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "fdt     : $([ -f /sys/firmware/fdt ] && echo 'present (DT boot)' || echo 'absent (ACPI boot)')"
  if [ -d /sys/firmware/efi/efivars ]; then
    echo "efi vars: present, $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l) variables"
  else
    echo "efi vars: ABSENT (/sys/firmware/efi/efivars missing -> efibootmgr cannot run)"
  fi
  echo "-- System RAM / Reserved (from /proc/iomem) --"
  grep -E '^[0-9a-f]{8,}-[0-9a-f]{8,} : (System RAM|Reserved|ACPI Tables|Soft Reserved|Crash)' /proc/iomem | head -24
  echo "-- input --"
  grep -E '^N: Name|^H: Handlers' /proc/bus/input/devices 2>/dev/null | head -12
  [ -s /proc/bus/input/devices ] || echo "  (none)"
  echo "-- i2c adapters --"
  ls /sys/bus/i2c/devices 2>/dev/null | head -12
  [ -d /sys/bus/i2c/devices ] || echo "  (no i2c bus class)"
  echo "-- hid devices --"
  ls /sys/bus/hid/devices 2>/dev/null | head -10
  echo "-- qcom acpi devices --"
  for d in /sys/bus/acpi/devices/*; do
    h="$(cat "$d/hid" 2>/dev/null)"
    case "$h" in QCOM*|ASU*|QTEC*|MSFT*|PNP0C50|ACPI0C50) echo "  $h uid=$(cat "$d/uid" 2>/dev/null)";; esac
  done | head -20
  echo "-- efi systab --"
  cat /sys/firmware/efi/systab 2>/dev/null | head -12
  echo "sink    : $SINK_DESC"
  echo "============= END HARVEST ============="
} > /dev/console 2>&1

# --------------------------------------------------------------------- sinks
TAR="$W/a16-harvest-$STAMP.tar.gz"          # everything, including ACPI tables
TAR_TEXT="$W/a16-harvest-$STAMP-text.tar.gz" # text only, ~100 kB, fits anywhere
tar czf "$TAR" -C "$W" data 2>/dev/null || tar cf "${TAR%.gz}" -C "$W" data
tar czf "$TAR_TEXT" -C "$W" --exclude=data/acpi-tables --exclude=data/firmware.dtb data 2>/dev/null
TAR_BYTES="$(wc -c < "$TAR" 2>/dev/null || echo 0)"
TEXT_BYTES="$(wc -c < "$TAR_TEXT" 2>/dev/null || echo 0)"

SINK_DESC="none (console summary only)"
attempts=""

free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

sink_write() {  # sink_write <mountpoint> <description>
  mnt="$1"; desc="$2"
  have="$(free_kb "$mnt")"
  if [ -n "$have" ] && [ "$have" -gt $((TAR_BYTES / 1024 + 64)) ]; then
    cp "$TAR" "$mnt/" 2>/dev/null || attempts="$attempts $desc:copy-failed"
  elif [ -n "$have" ] && [ "$have" -gt $((TEXT_BYTES / 1024 + 32)) ]; then
    # Space for the text harvest only: ACPI tables can be re-dumped from
    # Windows, dmesg/iomem/device lists cannot.
    cp "$TAR_TEXT" "$mnt/" 2>/dev/null || attempts="$attempts $desc:text-copy-failed"
    attempts="$attempts $desc:text-only"
  else
    attempts="$attempts $desc:no-space(${have:-?}kB)"
    cp "$D/summary.txt" "$mnt/a16-summary-$STAMP.txt" 2>/dev/null || true
    gzip -c "$D/dmesg.txt" > "$mnt/a16-dmesg-$STAMP.txt.gz" 2>/dev/null || true
  fi
  sync
  SINK_DESC="$desc ($mnt)"
  umount "$mnt" 2>/dev/null
  return 0
}

# The internal ESP is the best sink: ample space, plain FAT, and readable from
# Windows by assigning it a drive letter (see a16-read-log.ps1). The live
# medium's own ESP is the fallback but only has ~1 MB free on this media.
for part in $(lsblk -rpno NAME,FSTYPE,LABEL 2>/dev/null | awk '$2=="vfat"||$2=="exfat"||$2=="ext4"{print $1"|"$3}'); do
  [ -n "$SINK_DESC" ] && [ "$SINK_DESC" != "none (console summary only)" ] && break
  dev="${part%%|*}"; label="${part##*|}"
  mnt="/mnt/a16-sink"
  mkdir -p "$mnt"
  [ "$label" = "A16LOG" ] && { mount -o rw "$dev" "$mnt" 2>/dev/null && sink_write "$mnt" "labelled A16LOG volume" && break; umount "$mnt" 2>/dev/null; }
  mount -o ro "$dev" "$mnt" 2>/dev/null || continue
  if [ -d "$mnt/EFI/Microsoft" ]; then
    umount "$mnt" 2>/dev/null
    mount -o rw "$dev" "$mnt" 2>/dev/null && sink_write "$mnt" "internal EFI system partition" && break
  elif [ -f "$mnt/EFI/BOOT/BOOTAA64.EFI" ]; then
    umount "$mnt" 2>/dev/null
    mount -o rw "$dev" "$mnt" 2>/dev/null && sink_write "$mnt" "live medium ESP" && break
  fi
  umount "$mnt" 2>/dev/null
done

# Report where the collector landed, where the operator will look for it.
{
  echo "sink    : $SINK_DESC"
  echo "tarball : full $TAR_BYTES B / text-only $TEXT_BYTES B"
  [ -n "$attempts" ] && echo "skipped :$attempts"
} > /dev/console 2>&1
exit 0

