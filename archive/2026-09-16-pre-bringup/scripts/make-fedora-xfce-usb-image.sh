#!/usr/bin/env bash
# Overlay a custom ARM64 kernel bundle on a Fedora Xfce ARM64 raw USB image.
set -Eeuo pipefail

on_error() {
  local status="$1" line="$2" command="$3"
  echo "Image builder failed (exit $status) at line $line: $command" >&2
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
BASE_URL="${2:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
OUT="${OUT:-$PWD/out}"
COMPRESS="${COMPRESS:-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ROOT/build/downloads}"
BASE_IMAGE_SHA256="${BASE_IMAGE_SHA256:-}"
source "$ROOT/config/build.env"
source /etc/os-release
BUILD_HOST_OS="${ID:-unknown}"
WORK="$(mktemp -d)"
LOOP_DEV=""
HOST_MODULE_BIND=""
HOST_MODULE_DIR_CREATED=0
CHROOT_PROC_MOUNTED=0
CHROOT_SYS_MOUNTED=0
CHROOT_DEV_MOUNTED=0
ROOT_MOUNT="$WORK/root"
BOOT_MOUNT="$ROOT_MOUNT/boot"
cleanup() {
  if [[ "$CHROOT_DEV_MOUNTED" == 1 ]]; then sudo umount -R "$ROOT_MOUNT/dev" || true; fi
  if [[ "$CHROOT_SYS_MOUNTED" == 1 ]]; then sudo umount -R "$ROOT_MOUNT/sys" || true; fi
  if [[ "$CHROOT_PROC_MOUNTED" == 1 ]]; then sudo umount -R "$ROOT_MOUNT/proc" || true; fi
  if [[ -n "$HOST_MODULE_BIND" ]] && sudo mountpoint -q "$HOST_MODULE_BIND"; then sudo umount "$HOST_MODULE_BIND"; fi
  if [[ "$HOST_MODULE_DIR_CREATED" == 1 ]]; then sudo rmdir "$HOST_MODULE_BIND" 2>/dev/null || true; fi
  sudo mountpoint -q "$BOOT_MOUNT" && sudo umount "$BOOT_MOUNT" || true
  sudo mountpoint -q "$ROOT_MOUNT" && sudo umount "$ROOT_MOUNT" || true
  [[ -n "$LOOP_DEV" ]] && sudo losetup -d "$LOOP_DEV" || true
  rm -rf "$WORK"
}
trap cleanup EXIT

run_host_dracut() {
  local logfile="$1"
  shift
  local -a statuses
  if "$@" 2>&1 | tee "$logfile"; then
    return 0
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  local status="${statuses[0]}"
  echo "Fedora host dracut failed with exit status $status" >&2
  if [[ -s "$logfile" ]]; then
    echo "Last 120 lines of dracut log ($logfile):" >&2
    tail -n 120 "$logfile" >&2
  fi
  return "$status"
}

for cmd in curl sha256sum xz tar awk cpio rpm2cpio depmod lsblk losetup mount mountpoint partprobe pv udevadm sudo; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }; done
mkdir -p "$OUT"
mkdir -p "$DOWNLOAD_DIR"

BASE_IMAGE="$DOWNLOAD_DIR/$(basename "$BASE_URL")"
verify_base_image() {
  [[ -s "$BASE_IMAGE" ]] || return 1
  xz -t "$BASE_IMAGE" || return 1
  [[ -z "$BASE_IMAGE_SHA256" ]] || printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_IMAGE" | sha256sum --check --status
}

if verify_base_image; then
  echo "Reusing verified Fedora Xfce ARM64 base image: $BASE_IMAGE"
else
  if [[ -f "$BASE_IMAGE" && -n "$BASE_IMAGE_SHA256" ]] && xz -t "$BASE_IMAGE" >/dev/null 2>&1 && ! printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_IMAGE" | sha256sum --check --status; then
    # A complete but corrupt pinned file cannot be repaired with a byte-range
    # request. Keep it for inspection and start a clean download. An incomplete
    # xz stream is left in place so curl can resume it below.
    mv "$BASE_IMAGE" "$BASE_IMAGE.invalid.$(date +%s)"
  fi
  echo "Downloading Fedora Xfce ARM64 base image"
  for attempt in 1 2 3 4 5; do
    # Resume a partial image after an interrupted mirror connection. Keeping
    # the download outside WORK lets later launcher invocations reuse it.
    if curl --fail --location --retry 3 --retry-all-errors --continue-at - \
      "$BASE_URL" -o "$BASE_IMAGE"; then
      break
    fi
    if [[ "$attempt" == 5 ]]; then
      echo "Failed to download Fedora base image after $attempt attempts: $BASE_IMAGE" >&2
      exit 1
    fi
    echo "Download interrupted; resuming (attempt $((attempt + 1))/5)" >&2
  done
  verify_base_image || { echo "Downloaded Fedora base image failed verification: $BASE_IMAGE" >&2; exit 1; }
fi
echo "Expanding Fedora raw image"
pv -pterb "$BASE_IMAGE" | xz -T0 -d > "$WORK/fedora-a16-xfce.raw"

mkdir "$WORK/bundle"
tar --zstd -C "$WORK/bundle" -xf "$BUNDLE"
STAGE="$(find "$WORK/bundle" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$STAGE/Image" ]] || { echo "Invalid kernel bundle" >&2; exit 2; }
VERSION="$(basename "$STAGE")"; VERSION="${VERSION#zenbook-a16-}"
DTB_REL="dtb-$VERSION/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
[[ -f "$STAGE/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb" ]] || {
  echo "A16 DTB not found in kernel bundle" >&2; exit 2;
}

# Mount the raw disk directly. This works on GitHub-hosted Ubuntu runners and
# avoids libguestfs/supermin, which cannot reliably launch its appliance there.
mkdir -p "$BOOT_MOUNT"
LOOP_DEV="$(sudo losetup --find --show --partscan "$WORK/fedora-a16-xfce.raw")"
sudo partprobe "$LOOP_DEV"
sudo udevadm settle --timeout=15
lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINT "$LOOP_DEV"
sudo blkid || true
mapfile -t PARTITIONS < <(lsblk -lnpo NAME,TYPE "$LOOP_DEV" | awk '$2 == "part" {print $1}')
[[ ${#PARTITIONS[@]} -gt 0 ]] || { echo "No mountable partitions found in Fedora image" >&2; exit 2; }
PROBE="$WORK/probe"
mkdir "$PROBE"
ROOT_PART=""
ROOT_SUBVOL=""
BOOT_PART=""
for part in "${PARTITIONS[@]}"; do
  if sudo mount -o ro "$part" "$PROBE" 2>/dev/null; then
    if [[ -d "$PROBE/usr" && -d "$PROBE/etc" ]]; then ROOT_PART="$part"; fi
    if [[ -d "$PROBE/loader/entries" || -d "$PROBE/grub2" ]]; then BOOT_PART="$part"; fi
    sudo umount "$PROBE"
  fi
  # Fedora btrfs disk images normally use a top-level container with a `root`
  # subvolume. Inspect that container when the default mount has no /usr.
  if [[ -z "$ROOT_PART" && "$(lsblk -no FSTYPE "$part")" == "btrfs" ]] && sudo mount -o ro,subvolid=5 "$part" "$PROBE" 2>/dev/null; then
    for subvol in "$PROBE"/*; do
      if [[ -d "$subvol/usr" && -d "$subvol/etc" ]]; then
        ROOT_PART="$part"
        ROOT_SUBVOL="$(basename "$subvol")"
        break
      fi
    done
    sudo umount "$PROBE"
  fi
done
[[ -n "$ROOT_PART" ]] || { echo "Could not find Fedora root partition" >&2; exit 2; }
if [[ -n "$ROOT_SUBVOL" ]]; then
  sudo mount -o "subvol=$ROOT_SUBVOL" "$ROOT_PART" "$ROOT_MOUNT"
else
  sudo mount "$ROOT_PART" "$ROOT_MOUNT"
fi
[[ -d "$ROOT_MOUNT/usr" ]] || { echo "Fedora root subvolume was not mounted" >&2; exit 2; }
if [[ -n "$BOOT_PART" && "$BOOT_PART" != "$ROOT_PART" ]]; then
  sudo mount "$BOOT_PART" "$BOOT_MOUNT"
fi

# Overlay the newest Rawhide Qualcomm firmware package. The base image can lag
# the repository, while Glymur GPU/video/DSP firmware is still moving quickly.
echo "Checking latest Fedora Rawhide Qualcomm firmware"
QCOM_FIRMWARE_RPM="$(curl --fail --location --retry 3 "$QCOM_FIRMWARE_BASE_URL/" \
  | grep -oE 'qcom-firmware-[^"<]+\.noarch\.rpm' | sort -Vu | tail -n1)"
[[ -n "$QCOM_FIRMWARE_RPM" ]] || { echo "Could not locate qcom-firmware RPM" >&2; exit 2; }
QCOM_FIRMWARE_CACHE="$DOWNLOAD_DIR/$QCOM_FIRMWARE_RPM"
QCOM_FIRMWARE_PART="$QCOM_FIRMWARE_CACHE.part"
if [[ -s "$QCOM_FIRMWARE_CACHE" ]] && rpm2cpio "$QCOM_FIRMWARE_CACHE" | cpio -it --quiet >/dev/null 2>&1; then
  echo "Reusing cached Qualcomm firmware RPM: $QCOM_FIRMWARE_RPM"
else
  echo "Downloading updated Qualcomm firmware RPM: $QCOM_FIRMWARE_RPM"
  rm -f "$QCOM_FIRMWARE_CACHE"
  curl --fail --location --retry 3 --retry-all-errors --continue-at - \
    "$QCOM_FIRMWARE_BASE_URL/$QCOM_FIRMWARE_RPM" -o "$QCOM_FIRMWARE_PART"
  rpm2cpio "$QCOM_FIRMWARE_PART" | cpio -it --quiet >/dev/null || {
    echo "Downloaded Qualcomm firmware RPM is invalid: $QCOM_FIRMWARE_PART" >&2; exit 1;
  }
  mv "$QCOM_FIRMWARE_PART" "$QCOM_FIRMWARE_CACHE"
fi
mkdir "$WORK/qcom-firmware"
(cd "$WORK/qcom-firmware" && rpm2cpio "$QCOM_FIRMWARE_CACHE" | cpio -idm --quiet)
[[ -d "$WORK/qcom-firmware/usr/lib/firmware/qcom" ]] || {
  echo "Downloaded RPM has no Qualcomm firmware tree" >&2; exit 2;
}
sudo mkdir -p "$ROOT_MOUNT/usr/lib/firmware"
sudo cp -a "$WORK/qcom-firmware/usr/lib/firmware/." "$ROOT_MOUNT/usr/lib/firmware/"

echo "Checking latest Fedora Rawhide Atheros firmware"
ATHEROS_FIRMWARE_RPM="$(curl --fail --location --retry 3 "$ATHEROS_FIRMWARE_BASE_URL/" \
  | grep -oE 'atheros-firmware-[^"<]+\.noarch\.rpm' | sort -Vu | tail -n1)"
[[ -n "$ATHEROS_FIRMWARE_RPM" ]] || { echo "Could not locate atheros-firmware RPM" >&2; exit 2; }
ATHEROS_FIRMWARE_CACHE="$DOWNLOAD_DIR/$ATHEROS_FIRMWARE_RPM"
ATHEROS_FIRMWARE_PART="$ATHEROS_FIRMWARE_CACHE.part"
if [[ -s "$ATHEROS_FIRMWARE_CACHE" ]] && rpm2cpio "$ATHEROS_FIRMWARE_CACHE" | cpio -it --quiet >/dev/null 2>&1; then
  echo "Reusing cached Atheros firmware RPM: $ATHEROS_FIRMWARE_RPM"
else
  echo "Downloading updated Atheros firmware RPM: $ATHEROS_FIRMWARE_RPM"
  curl --fail --location --retry 3 --retry-all-errors --continue-at - \
    "$ATHEROS_FIRMWARE_BASE_URL/$ATHEROS_FIRMWARE_RPM" -o "$ATHEROS_FIRMWARE_PART"
  rpm2cpio "$ATHEROS_FIRMWARE_PART" | cpio -it --quiet >/dev/null || {
    echo "Downloaded Atheros firmware RPM is invalid: $ATHEROS_FIRMWARE_PART" >&2; exit 1;
  }
  mv "$ATHEROS_FIRMWARE_PART" "$ATHEROS_FIRMWARE_CACHE"
fi
mkdir "$WORK/atheros-firmware"
(cd "$WORK/atheros-firmware" && rpm2cpio "$ATHEROS_FIRMWARE_CACHE" | cpio -idm --quiet)
[[ -d "$WORK/atheros-firmware/usr/lib/firmware/ath12k/WCN7850" ]] || {
  echo "Downloaded Atheros RPM has no WCN7850 firmware tree" >&2; exit 2;
}
sudo cp -a "$WORK/atheros-firmware/usr/lib/firmware/." "$ROOT_MOUNT/usr/lib/firmware/"

# Keep Fedora's root-device command line, but do not retain any of its kernel
# files, initramfs images, module trees, or boot entries.  The completed USB
# image has exactly one kernel release: the A16 bundle release below.
ENTRY="$(sudo find "$BOOT_MOUNT/loader/entries" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | head -n1)"
[[ -n "$ENTRY" ]] || { echo "Could not locate Fedora boot entry" >&2; exit 2; }
OPTIONS="$(sudo sed -n 's/^options //p' "$BOOT_MOUNT/loader/entries/$ENTRY" | head -n1)"
[[ -n "$OPTIONS" ]] || { echo "Could not obtain Fedora kernel options" >&2; exit 2; }

echo "Removing Fedora kernel artifacts and boot entries"
sudo find "$BOOT_MOUNT" -maxdepth 1 -type f \( -name 'vmlinuz-*' -o -name 'Image-*' -o -name 'initramfs-*.img' \) -delete
sudo find "$BOOT_MOUNT" -maxdepth 1 -type d -name 'dtb-*' -exec rm -rf {} +
sudo find "$BOOT_MOUNT/loader/entries" -maxdepth 1 -type f -name '*.conf' -delete

# Strip graphical/quiet modes and stale diagnostics inherited from Fedora.
# The A16 entries intentionally boot to a text console. A desktop session is
# not useful until the early platform and display path is proven stable.
read -r -a FEDORA_OPTIONS <<< "$OPTIONS"
FILTERED_OPTIONS=()
for option in "${FEDORA_OPTIONS[@]}"; do
  case "$option" in
    rhgb|quiet|splash|nomodeset|rd.plymouth=*|plymouth.*|loglevel=*|ignore_loglevel|initcall_debug|initcall_blacklist=msm_drm_register|deferred_probe_timeout=*|systemd.show_status=*|rd.systemd.show_status=*|rootwait|module_blacklist=*|modprobe.blacklist=*|rd.driver.blacklist=*) ;;
    *) FILTERED_OPTIONS+=("$option") ;;
  esac
done
BASE_OPTIONS="${FILTERED_OPTIONS[*]} rd.plymouth=0 plymouth.enable=0 rootwait console=tty0 deferred_probe_timeout=60"
CONSOLE_OPTIONS="$BASE_OPTIONS systemd.unit=multi-user.target systemd.mask=display-manager.service"
NORMAL_OPTIONS="$CONSOLE_OPTIONS"
DEBUG_OPTIONS="$CONSOLE_OPTIONS loglevel=7 ignore_loglevel initcall_debug systemd.show_status=1 rd.systemd.show_status=1"
FIRMWARE_FB_OPTIONS="$DEBUG_OPTIONS initcall_blacklist=msm_drm_register module_blacklist=msm modprobe.blacklist=msm rd.driver.blacklist=msm"

# Install the custom module tree before invoking dracut.  Build the initramfs
# with Fedora's own dracut in an ARM64 emulation chroot: mixing Ubuntu dracut
# with Fedora's modules through --sysroot is not supported and breaks helper
# functions and dependency resolution.  A generic initramfs avoids host-only
# assumptions; force root-storage drivers and include Qualcomm firmware.
A16_INITRD="initramfs-$VERSION-a16.img"
sudo rm -rf "$ROOT_MOUNT/usr/lib/modules"
sudo mkdir -p "$ROOT_MOUNT/usr/lib/modules"
sudo cp -a "$STAGE/modules/lib/modules/$VERSION" "$ROOT_MOUNT/usr/lib/modules/"
sudo depmod -b "$ROOT_MOUNT" "$VERSION"
STORAGE_DRIVERS="nvme ahci sd_mod usb-storage uas dm_mod dm_crypt btrfs ext4 vfat xhci-pci xhci-hcd pcie-qcom phy-qcom-qmp-pcie dwc3"
AVAILABLE_STORAGE_DRIVERS=()
for driver in $STORAGE_DRIVERS; do
  module_name="${driver//_/-}"
  if find "$ROOT_MOUNT/usr/lib/modules/$VERSION" -type f -name "$module_name.ko*" -print -quit | grep -q .; then
    AVAILABLE_STORAGE_DRIVERS+=("$module_name")
  elif find "$ROOT_MOUNT/usr/lib/modules/$VERSION" -type f -name "$driver.ko*" -print -quit | grep -q .; then
    AVAILABLE_STORAGE_DRIVERS+=("$driver")
  else
    echo "Storage driver built in or absent from module tree: $driver"
  fi
done
DRACUT_STORAGE_DRIVERS="${AVAILABLE_STORAGE_DRIVERS[*]}"
[[ -n "$DRACUT_STORAGE_DRIVERS" ]] || echo "All requested storage drivers are built into the custom kernel"
if [[ "$BUILD_HOST_OS" == fedora ]]; then
  command -v dracut >/dev/null || { echo "Missing Fedora host tool: dracut" >&2; exit 2; }
  echo "Generating initramfs with Fedora host dracut"
  mkdir -p "$WORK/dracut-tmp"
  # Fedora dracut resolves /lib/modules/$VERSION before applying --kmoddir.
  # Temporarily bind the custom tree there, then reliably remove it in cleanup.
  HOST_MODULE_BIND="/lib/modules/$VERSION"
  [[ ! -e "$HOST_MODULE_BIND" ]] || {
    echo "Host already has a module directory for custom release: $HOST_MODULE_BIND" >&2; exit 2;
  }
  sudo mkdir -p "$HOST_MODULE_BIND"
  HOST_MODULE_DIR_CREATED=1
  sudo mount --bind "$ROOT_MOUNT/usr/lib/modules/$VERSION" "$HOST_MODULE_BIND"
  DRACUT_LOG="$WORK/dracut-host.log"
  run_host_dracut "$DRACUT_LOG" sudo dracut --force --no-hostonly --tmpdir "$WORK/dracut-tmp" --kver "$VERSION" \
    --kmoddir "$HOST_MODULE_BIND" \
    --fwdir "$ROOT_MOUNT/usr/lib/firmware" \
    --add-drivers "$DRACUT_STORAGE_DRIVERS" --force-drivers "$DRACUT_STORAGE_DRIVERS" \
    --include "$ROOT_MOUNT/usr/lib/firmware/qcom" /usr/lib/firmware/qcom \
    --include "$ROOT_MOUNT/usr/lib/firmware/ath12k" /usr/lib/firmware/ath12k \
    "$BOOT_MOUNT/$A16_INITRD"
  sudo umount "$HOST_MODULE_BIND"
  sudo rmdir "$HOST_MODULE_BIND"
  HOST_MODULE_BIND=""
  HOST_MODULE_DIR_CREATED=0
else
  echo "Generating initramfs with Fedora image dracut (host OS: $BUILD_HOST_OS)"
  [[ -x "$ROOT_MOUNT/usr/bin/dracut" ]] || { echo "Fedora base image does not provide /usr/bin/dracut" >&2; exit 2; }
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
      [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || {
        echo "Missing ARM64 binfmt support; install qemu-user-binfmt" >&2; exit 2;
      }
      ;;
  esac
  # Fedora's dracut module setup scripts use /proc, /sys and /dev/fd. Bind
  # the host pseudo-filesystems into the disposable image chroot for the
  # duration of initramfs generation.
  sudo mkdir -p "$ROOT_MOUNT/proc" "$ROOT_MOUNT/sys" "$ROOT_MOUNT/dev"
  sudo mount --rbind /proc "$ROOT_MOUNT/proc"; CHROOT_PROC_MOUNTED=1
  sudo mount --make-rslave "$ROOT_MOUNT/proc"
  sudo mount --rbind /sys "$ROOT_MOUNT/sys"; CHROOT_SYS_MOUNTED=1
  sudo mount --make-rslave "$ROOT_MOUNT/sys"
  sudo mount --rbind /dev "$ROOT_MOUNT/dev"; CHROOT_DEV_MOUNTED=1
  sudo mount --make-rslave "$ROOT_MOUNT/dev"
  sudo install -d -m 1777 "$ROOT_MOUNT/var/tmp/dracut"
  sudo chroot "$ROOT_MOUNT" /usr/bin/dracut --force --no-hostonly --tmpdir /var/tmp/dracut --kver "$VERSION" \
    --add-drivers "$DRACUT_STORAGE_DRIVERS" --force-drivers "$DRACUT_STORAGE_DRIVERS" \
    --include /usr/lib/firmware/qcom /usr/lib/firmware/qcom \
    --include /usr/lib/firmware/ath12k /usr/lib/firmware/ath12k \
    "/boot/$A16_INITRD"
  sudo rm -rf "$ROOT_MOUNT/var/tmp/dracut"
  sudo umount -R "$ROOT_MOUNT/dev"; CHROOT_DEV_MOUNTED=0
  sudo umount -R "$ROOT_MOUNT/sys"; CHROOT_SYS_MOUNTED=0
  sudo umount -R "$ROOT_MOUNT/proc"; CHROOT_PROC_MOUNTED=0
fi

write_bls_entry() {
  local output="$1" title="$2" options="$3"
  cat > "$output" <<EOF
title $title
version $VERSION
linux /Image-$VERSION
initrd /$A16_INITRD
devicetree /$DTB_REL
options $options
EOF
}

write_grub_entry() {
  local title="$1" options="$2"
  cat >> "$WORK/a16-grub.cfg" <<EOF

menuentry '$title' {
    linux /Image-$VERSION $options
    initrd /$A16_INITRD
    devicetree /$DTB_REL
}
EOF
}

: > "$WORK/a16-grub.cfg"
write_bls_entry "$WORK/a16-normal.conf" \
  "Fedora - ASUS Zenbook A16 (text console)" "$NORMAL_OPTIONS"
write_bls_entry "$WORK/a16-debug.conf" \
  "Fedora - ASUS Zenbook A16 (text console, debug logging)" "$DEBUG_OPTIONS"
write_bls_entry "$WORK/a16-firmware-fb.conf" \
  "Fedora - ASUS Zenbook A16 (text console, firmware framebuffer, MSM DRM disabled)" "$FIRMWARE_FB_OPTIONS"
write_grub_entry "Fedora - ASUS Zenbook A16 (text console)" "$NORMAL_OPTIONS"
write_grub_entry "Fedora - ASUS Zenbook A16 (text console, debug logging)" "$DEBUG_OPTIONS"
write_grub_entry "Fedora - ASUS Zenbook A16 (text console, firmware framebuffer, MSM DRM disabled)" "$FIRMWARE_FB_OPTIONS"

sudo install -m 0644 "$STAGE/Image" "$BOOT_MOUNT/Image-$VERSION"
sudo cp -a "$STAGE/dtbs" "$BOOT_MOUNT/dtb-$VERSION"
sudo mkdir -p "$ROOT_MOUNT/usr/share/a16-build"
sudo cp -a "$STAGE/metadata/." "$ROOT_MOUNT/usr/share/a16-build/"
printf '%s\n' "$QCOM_FIRMWARE_RPM" | sudo tee "$ROOT_MOUNT/usr/share/a16-build/qcom-firmware-rpm.txt" >/dev/null
printf '%s\n' "$NORMAL_OPTIONS" | sudo tee "$ROOT_MOUNT/usr/share/a16-build/kernel-command-line-normal.txt" >/dev/null
printf '%s\n' "$DEBUG_OPTIONS" | sudo tee "$ROOT_MOUNT/usr/share/a16-build/kernel-command-line-debug.txt" >/dev/null
printf '%s\n' "$FIRMWARE_FB_OPTIONS" | sudo tee "$ROOT_MOUNT/usr/share/a16-build/kernel-command-line-firmware-fb.txt" >/dev/null
sudo install -m 0644 "$WORK/a16-normal.conf" "$BOOT_MOUNT/loader/entries/a16-$VERSION-normal.conf"
sudo install -m 0644 "$WORK/a16-debug.conf" "$BOOT_MOUNT/loader/entries/a16-$VERSION-debug.conf"
sudo install -m 0644 "$WORK/a16-firmware-fb.conf" "$BOOT_MOUNT/loader/entries/a16-$VERSION-firmware-fb.conf"
# Some Fedora ARM images do not refresh GRUB's BLS enumeration on a copied raw
# image. Keep the BLS entry and append an explicit GRUB fallback so the test
# kernel is always selectable without becoming the default.
if [[ -f "$BOOT_MOUNT/grub2/grub.cfg" ]]; then
  sudo tee -a "$BOOT_MOUNT/grub2/grub.cfg" < "$WORK/a16-grub.cfg" >/dev/null
fi

verify_final_image() {
  local -a releases entries
  mapfile -t releases < <(sudo find "$ROOT_MOUNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  [[ ${#releases[@]} == 1 && "${releases[0]}" == "$VERSION" ]] || {
    echo "Final image must contain only module release $VERSION; found: ${releases[*]:-none}" >&2; return 1;
  }
  [[ -f "$BOOT_MOUNT/Image-$VERSION" && -f "$BOOT_MOUNT/$A16_INITRD" && -f "$BOOT_MOUNT/$DTB_REL" ]] || {
    echo "Custom kernel, initramfs, or A16 DTB is missing from final boot partition" >&2; return 1;
  }
  [[ "$(sudo find "$BOOT_MOUNT" -maxdepth 1 -type f \( -name 'vmlinuz-*' -o -name 'Image-*' -o -name 'initramfs-*.img' \) -printf '%f\n' | sort)" == $'Image-'"$VERSION"$'\ninitramfs-'"$VERSION"$'-a16.img' ]] || {
    echo "Fedora kernel or initramfs artifact remains on final boot partition" >&2; return 1;
  }
  mapfile -t entries < <(sudo find "$BOOT_MOUNT/loader/entries" -maxdepth 1 -type f -name '*.conf' -print | sort)
  [[ ${#entries[@]} == 3 ]] || { echo "Expected exactly three A16 BLS entries" >&2; return 1; }
  for entry in "${entries[@]}"; do
    [[ "$(basename "$entry")" == "a16-$VERSION-"*.conf ]] || {
      echo "Non-A16 BLS kernel entry remains on final image: $entry" >&2; return 1;
    }
    sudo grep -qx "linux /Image-$VERSION" "$entry"
    sudo grep -qx "initrd /$A16_INITRD" "$entry"
    sudo grep -qx "devicetree /$DTB_REL" "$entry"
  done
  # Do not pipe lsinitrd into grep -q: grep intentionally closes early after
  # a match, which makes lsinitrd receive SIGPIPE and fail under pipefail.
  sudo lsinitrd "$BOOT_MOUNT/$A16_INITRD" > "$WORK/a16-initramfs-listing.txt"
  grep -q "usr/lib/firmware/qcom" "$WORK/a16-initramfs-listing.txt"
  grep -q "usr/lib/firmware/ath12k/WCN7850" "$WORK/a16-initramfs-listing.txt"
  grep -q "usr/lib/modules/$VERSION" "$WORK/a16-initramfs-listing.txt"
}
verify_final_image
KERNEL_IMAGE_BYTES="$(sudo stat -c%s "$BOOT_MOUNT/Image-$VERSION")"
INITRAMFS_BYTES="$(sudo stat -c%s "$BOOT_MOUNT/$A16_INITRD")"
DTB_BYTES="$(sudo stat -c%s "$BOOT_MOUNT/$DTB_REL")"
MODULE_TREE_BYTES="$(sudo du -sb "$ROOT_MOUNT/usr/lib/modules/$VERSION" | awk '{print $1}')"

# All filesystem writes must reach the raw backing file before it is compressed.
# Keeping the image mounted here previously produced an artifact with the
# pre-edit boot partition despite a successful workflow run.
echo "Flushing image filesystem changes"
sync
if sudo mountpoint -q "$BOOT_MOUNT"; then sudo umount "$BOOT_MOUNT"; fi
if sudo mountpoint -q "$ROOT_MOUNT"; then sudo umount "$ROOT_MOUNT"; fi
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

if [[ "$COMPRESS" == 1 ]]; then
  FINAL="$OUT/fedora-xfce-a16-$VERSION.raw.xz"
  echo "Compressing finished USB image"
  pv -pterb -s "$(stat -c%s "$WORK/fedora-a16-xfce.raw")" "$WORK/fedora-a16-xfce.raw" | xz -T0 -1 > "$FINAL"
else
  FINAL="$OUT/fedora-xfce-a16-$VERSION.raw"
  echo "Keeping finished USB image uncompressed"
  mv "$WORK/fedora-a16-xfce.raw" "$FINAL"
fi
FINAL_ARTIFACT_BYTES="$(stat -c%s "$FINAL")"
echo "Writing checksum"
sha256sum "$FINAL" > "$FINAL.sha256"
if [[ "$COMPRESS" == 1 ]]; then
  echo "Verifying compressed USB image"
  xz -t "$FINAL"
fi
sha256sum -c "$FINAL.sha256"
if [[ -n "${SPLIT_SIZE:-}" ]]; then
  [[ "$COMPRESS" == 1 ]] || { echo "SPLIT_SIZE requires COMPRESS=1" >&2; exit 2; }
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  echo "Split image into $(basename "$FINAL").00.part, .01.part, ..."
fi

print_build_summary() {
  local output_description
  if [[ -n "${SPLIT_SIZE:-}" ]]; then
    output_description="$(basename "$FINAL").00.part, .01.part, ..."
  else
    output_description="$(basename "$FINAL")"
  fi
  cat <<EOF

========== A16 Fedora USB build summary ==========
Host OS: ${PRETTY_NAME:-$BUILD_HOST_OS}
Host kernel: $(uname -srmo)
Kernel release: $VERSION
Fedora base image: $BASE_URL
Qualcomm firmware RPM: $QCOM_FIRMWARE_RPM ($(stat -c%s "$QCOM_FIRMWARE_CACHE") bytes, cached in $DOWNLOAD_DIR)
Atheros firmware RPM: $ATHEROS_FIRMWARE_RPM ($(stat -c%s "$ATHEROS_FIRMWARE_CACHE") bytes, cached in $DOWNLOAD_DIR)
Custom Image: $KERNEL_IMAGE_BYTES bytes
Custom initramfs: $INITRAMFS_BYTES bytes
A16 DTB: $DTB_BYTES bytes
Custom module tree: $MODULE_TREE_BYTES bytes
Final artifact: $output_description
Final artifact size before splitting: $FINAL_ARTIFACT_BYTES bytes
Checksum: $(basename "$FINAL").sha256
Boot payload: only Image-$VERSION, $A16_INITRD, dtb-$VERSION, and /usr/lib/modules/$VERSION
==================================================
EOF
}
print_build_summary
