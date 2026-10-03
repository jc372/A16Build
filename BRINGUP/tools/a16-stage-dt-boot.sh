#!/usr/bin/env bash
# a16-stage-dt-boot.sh -- put the Zenbook A16's glymur DTB on the ESP and add a
# devicetree boot entry beside the existing ACPI one, so the internal keyboard /
# touchpad / touchscreen can come up (they are i2c-HID devices that only exist
# in the devicetree description; under ACPI the geni I2C controllers never bind).
#
# Run as root, from anywhere:
#     sudo bash /home/jc/a16-payload/a16-stage-dt-boot.sh
#
# What it does NOT do: touch the installed system's own /boot/grub/grub.cfg, the
# installed kernel, or the payload's linux-next kernel (that one, path B, would
# additionally need its modules installed and an initramfs built for it).
#
# Design rules (from the arm64-laptop-bringup workflow): never fail the run hard,
# no `set -e`, guard every step, capture stdout AND stderr AND exit codes, print
# the reason a step was skipped, and write the log back to the FAT volume so the
# whole run is readable afterwards (from here, or from the other OS).
set -u

STAGE_DIR="/home/jc/a16-payload"
BUNDLE="${A16_BUNDLE:-$STAGE_DIR/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst}"
DTB_IN_TAR="zenbook-a16-7.3.0-rc3-next-20260914/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_NAME="glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_SHA="ddb423f8dda683a965c1ffe6c4933d15bd9714dae7e740faf8d306b968056ac2"
UUID_ROOT="f8e005e9-414c-4c8e-ad68-d1e9fdc208bc"
CFG_SRC="${A16_CFG:-$STAGE_DIR/a16-dt-grub.cfg}"
# ESP can be pointed elsewhere for a dry run (A16_ESP=/tmp/fake-esp), and the
# root requirement relaxed the same way (A16_ALLOW_NONROOT=1) -- test mode only.
ESP="${A16_ESP:-/boot/efi}"
BACKUP="$ESP/A16ESP-BACKUP"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/a16-stage-dt-XXXXXX" 2>/dev/null || echo /var/tmp/a16-stage-dt-$$)"
mkdir -p "$WORK" 2>/dev/null

is_mounted() { grep -qs " $1 " /proc/mounts; }
LOG=""
log() { printf '[a16-stage-dt] %s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
run() {  # run <label> <cmd...> -- returns the command's status (not tee's)
  local label="$1"; shift
  local out st
  out="$("$@" 2>&1)"; st=$?
  { echo "### \$ $*"; printf '%s\n' "$out"; echo "### exit: $st"; } | tee -a "${LOG:-/dev/null}"
  return $st
}

# ---- 0. must be root -------------------------------------------------------
if [ "$(id -u)" != "0" ] && [ "${A16_ALLOW_NONROOT:-0}" != "1" ]; then
  echo "[a16-stage-dt] needs root. Re-run as:"
  echo "    sudo bash $0"
  exit 1
fi

# ---- 1. pick a log sink (prefer the ESP, so the log is readable from Windows) --
# Writable-ESP check only: this runs before the mount step, and a false negative
# here just puts the log in /var/tmp.
if touch "$ESP/.a16w" 2>/dev/null; then
  rm -f "$ESP/.a16w"; LOG="$ESP/A16DTBOOT.LOG"
else
  LOG="/var/tmp/A16DTBOOT.LOG"
fi
: > "$LOG"
log "=== a16-stage-dt-boot $STAMP  kernel=$(uname -r) ==="
log "log: $LOG"

# ---- 2. preconditions ------------------------------------------------------
log "=== preconditions ==="
log "uid=$(id -u) host=$(hostname) esp=$ESP bundle=$BUNDLE"
for t in tar zstd sha256sum install dtc strings tee; do
  if command -v "$t" >/dev/null 2>&1; then log "tool $t: $(command -v $t)"
  else log "tool $t: MISSING -- aborting (need it)"; exit 1; fi
done
[ -f "$CFG_SRC" ] || { log "MISSING config source $CFG_SRC -- aborting"; exit 1; }
[ -f "$BUNDLE" ]  || { log "MISSING kernel bundle $BUNDLE -- aborting"; exit 1; }
log "config source sha256: $(sha256sum "$CFG_SRC" 2>/dev/null | cut -d' ' -f1)"
log "bundle size: $(stat -c %s "$BUNDLE" 2>/dev/null) bytes"

# ---- 3. ESP mounted read-write --------------------------------------------
log "=== ESP mount ==="
MOUNTED_BY_US=no
if is_mounted "$ESP"; then
  log "$ESP is already mounted: $(grep -s " $ESP " /proc/mounts)"
elif [ "${A16_ALLOW_NONROOT:-0}" = "1" ]; then
  log "$ESP is not a mountpoint but A16_ALLOW_NONROOT=1 (dry run) -- using it as-is"
else
  log "$ESP is NOT mounted -- mounting it"
  run "mount" mount "$ESP" || { log "mount failed -- aborting"; exit 1; }
  MOUNTED_BY_US=yes
  is_mounted "$ESP" || { log "$ESP still not a mountpoint after mount -- aborting (refusing to write to the root fs by mistake)"; exit 1; }
fi
if touch "$ESP/.a16w" 2>/dev/null; then rm -f "$ESP/.a16w"; log "$ESP is writable"
else log "$ESP is NOT writable -- aborting"; exit 1; fi
run "df" df -h "$ESP"

# ---- 4. before-state: what config files exist, and what reads them ---------
log "=== before: ESP payload and boot configs ==="
run "ls-a16boot" ls -la "$ESP/a16boot"
log "--- grub.cfg candidates (size + sha256) ---"
for f in "$ESP/EFI/Boot/grub.cfg" "$ESP/EFI/ubuntu/grub.cfg" "$ESP/a16boot/grub.cfg" \
         "$ESP/EFI/ubuntu_snapdragon/grub.cfg"; do
  if [ -f "$f" ]; then printf '[a16-stage-dt]   %-48s %8s  %s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" | tee -a "$LOG"
  else printf '[a16-stage-dt]   %-48s (absent)\n' "$f" | tee -a "$LOG"; fi
done
log "--- embedded GRUB prefixes (which config each binary reads) ---"
for b in "$ESP/EFI/Boot/grubaa64.efi" "$ESP/EFI/Boot/BOOTAA64.EFI" \
         "$ESP/EFI/ubuntu/grubaa64.efi" "$ESP/EFI/ubuntu_snapdragon/grubaa64.efi"; do
  [ -f "$b" ] || continue
  printf '[a16-stage-dt]   %-50s %s\n' "$b" "$(strings -a -n 6 "$b" 2>/dev/null | grep -E '^/EFI/|^/boot/grub$' | sort -u | tr '\n' ' ')" | tee -a "$LOG"
done
log "--- installed root (left untouched) ---"
if [ -f /etc/fstab ]; then
  if grep -q "$UUID_ROOT" /etc/fstab; then log "fstab carries $UUID_ROOT: OK"
  else log "WARNING: /etc/fstab does not carry $UUID_ROOT -- check the menuentry UUIDs"; fi
fi
log "installed /boot/grub/grub.cfg: $(stat -c '%s bytes mtime=%y' /boot/grub/grub.cfg 2>/dev/null || echo unreadable)"

# ---- 5. DTB: extract, verify identity, verify it is the right machine -----
log "=== DTB ==="
if ! ( cd "$WORK" && tar -xf "$BUNDLE" "$DTB_IN_TAR" 2>&1 | tee -a "$LOG" ); then
  log "tar extraction failed -- aborting"; exit 1
fi
SRC_DTB="$WORK/$DTB_IN_TAR"
if [ ! -f "$SRC_DTB" ]; then log "extracted DTB not found at $SRC_DTB -- aborting"; exit 1; fi
GOT_SHA="$(sha256sum "$SRC_DTB" | cut -d' ' -f1)"
log "extracted sha256: $GOT_SHA"
log "expected  sha256: $DTB_SHA"
if [ "$GOT_SHA" != "$DTB_SHA" ]; then
  log "SHA256 MISMATCH -- refusing to install this DTB"; exit 1
fi
log "identity OK; model/compatible from the DTB:"
dtc -I dtb -O dts -o "$WORK/dtb.dts" "$SRC_DTB" >/dev/null 2>"$WORK/dtc.err"
grep -m1 -E '^\s+model =' "$WORK/dtb.dts" 2>/dev/null | sed 's/^/[a16-stage-dt]   /' | tee -a "$LOG"
grep -m1 -E '^\s+compatible = "asus,zenbook-a16' "$WORK/dtb.dts" 2>/dev/null | sed 's/^/[a16-stage-dt]   /' | tee -a "$LOG"
log "i2c-hid devices declared in it: $(grep -c 'compatible = "hid-over-i2c"' "$WORK/dtb.dts" 2>/dev/null)"

log "installing -> $ESP/a16boot/$DTB_NAME"
run "install-dtb" install -m 0644 "$SRC_DTB" "$ESP/a16boot/$DTB_NAME" || { log "install failed -- aborting"; exit 1; }
ESP_SHA="$(sha256sum "$ESP/a16boot/$DTB_NAME" | cut -d' ' -f1)"
if [ "$ESP_SHA" = "$DTB_SHA" ]; then log "on-ESP DTB sha256 verified: $ESP_SHA"
else log "on-ESP DTB sha256 MISMATCH ($ESP_SHA) -- investigate"; fi

# ---- 6. back up every config we are about to replace ----------------------
log "=== backups ==="
mkdir -p "$BACKUP" 2>/dev/null
for f in "$ESP/EFI/Boot/grub.cfg" "$ESP/EFI/ubuntu/grub.cfg" "$ESP/a16boot/grub.cfg" \
         "$ESP/EFI/ubuntu_snapdragon/grub.cfg"; do
  [ -f "$f" ] || continue
  tag="$(echo "$f" | sed "s|$ESP/||; s|/|_|g")"
  run "backup" cp -p "$f" "$BACKUP/${tag}.bak-$STAMP" || log "backup of $f failed (continuing)"
done
run "ls-backup" ls -la "$BACKUP"

# ---- 7. install the new config everywhere GRUB might read it -------------
log "=== install config ==="
for f in "$ESP/EFI/Boot/grub.cfg" "$ESP/EFI/ubuntu/grub.cfg" "$ESP/a16boot/grub.cfg" \
         "$ESP/EFI/ubuntu_snapdragon/grub.cfg"; do
  d="$(dirname "$f")"
  if [ ! -d "$d" ]; then log "skip $f (directory $d does not exist)"; continue; fi
  run "install-cfg" install -m 0755 "$CFG_SRC" "$f" || { log "install to $f failed"; continue; }
  n_devtree="$(grep -c '^\s*devicetree ' "$f" 2>/dev/null)"
  printf '[a16-stage-dt]   %-48s %8s  %s  devicetree-lines=%s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "$n_devtree" | tee -a "$LOG"
done

# ---- 8. summary -----------------------------------------------------------
log "=== summary ==="
log "DTB installed at : $ESP/a16boot/$DTB_NAME  (sha256 $DTB_SHA)"
log "menu written to : EFI/Boot/grub.cfg, EFI/ubuntu/grub.cfg, a16boot/grub.cfg, EFI/ubuntu_snapdragon/grub.cfg"
log "entries         : (from $(basename "$CFG_SRC"))"
grep -E '^menuentry' "$CFG_SRC" 2>/dev/null | sed 's/^menuentry "//; s/" {$//' | sed 's/^/[a16-stage-dt]                   /' | tee -a "$LOG"
log "next boot       : pick entry [1].  The screen should behave as it does on entry [0];"
log "                  the internal keyboard/touchpad/touchscreen come from DT."
log "                  Entry [1] falls back to the menu after 20s if the DTB is missing."
log "after the boot  : bash $STAGE_DIR/a16-dt-verify.sh   (writes an input/i2c report)"
log "note            : re-running a16-stage-esp-boot.sh will overwrite these configs"
log "                  and drop the DT entry; the DTB itself stays on the ESP."
log "=== done $STAMP ==="
sync
if [ "$MOUNTED_BY_US" = yes ]; then
  log "unmounting $ESP (we mounted it)"
  umount "$ESP" 2>/dev/null && log "unmounted" || log "umount failed -- left mounted"
fi
if [ -f "$LOG" ] && [ "$LOG" != "$STAGE_DIR/A16DTBOOT.LOG" ]; then
  cp -f "$LOG" "$STAGE_DIR/A16DTBOOT.LOG" 2>/dev/null
  chown --reference="$STAGE_DIR" "$STAGE_DIR/A16DTBOOT.LOG" 2>/dev/null
fi
echo "[a16-stage-dt] log written to $LOG (copy: $STAGE_DIR/A16DTBOOT.LOG)"
exit 0
