#!/usr/bin/env bash
# Overlay a custom ARM64 kernel bundle on a Fedora Xfce ARM64 raw USB image.
set -Eeuo pipefail

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
BASE_URL="${2:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
OUT="${OUT:-$PWD/out}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/build.env"
WORK="$(mktemp -d)"
LOOP_DEV=""
ROOT_MOUNT="$WORK/root"
BOOT_MOUNT="$ROOT_MOUNT/boot"
cleanup() {
  sudo mountpoint -q "$BOOT_MOUNT" && sudo umount "$BOOT_MOUNT" || true
  sudo mountpoint -q "$ROOT_MOUNT" && sudo umount "$ROOT_MOUNT" || true
  [[ -n "$LOOP_DEV" ]] && sudo losetup -d "$LOOP_DEV" || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for cmd in curl xz tar awk cpio gzip rpm2cpio depmod lsblk losetup mount mountpoint partprobe pv udevadm sudo; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }; done
mkdir -p "$OUT"

echo "Downloading Fedora Xfce ARM64 base image"
curl --fail --location --retry 3 "$BASE_URL" -o "$WORK/fedora.raw.xz"
echo "Expanding Fedora raw image"
pv -pterb "$WORK/fedora.raw.xz" | xz -T0 -d > "$WORK/fedora-a16-xfce.raw"

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
echo "Downloading latest Fedora Rawhide Qualcomm firmware"
QCOM_FIRMWARE_RPM="$(curl --fail --location --retry 3 "$QCOM_FIRMWARE_BASE_URL/" \
  | grep -oE 'qcom-firmware-[^"<]+\.noarch\.rpm' | sort -Vu | tail -n1)"
[[ -n "$QCOM_FIRMWARE_RPM" ]] || { echo "Could not locate qcom-firmware RPM" >&2; exit 2; }
curl --fail --location --retry 3 "$QCOM_FIRMWARE_BASE_URL/$QCOM_FIRMWARE_RPM" \
  -o "$WORK/$QCOM_FIRMWARE_RPM"
mkdir "$WORK/qcom-firmware"
(cd "$WORK/qcom-firmware" && rpm2cpio "$WORK/$QCOM_FIRMWARE_RPM" | cpio -idm --quiet)
[[ -d "$WORK/qcom-firmware/usr/lib/firmware/qcom" ]] || {
  echo "Downloaded RPM has no Qualcomm firmware tree" >&2; exit 2;
}
sudo mkdir -p "$ROOT_MOUNT/usr/lib/firmware"
sudo cp -a "$WORK/qcom-firmware/usr/lib/firmware/." "$ROOT_MOUNT/usr/lib/firmware/"

# Reuse Fedora's proven generic initramfs and root options. The custom Image and
# matching modules/DTB are added as a separate BLS menu entry; nothing becomes
# the default boot choice.
INITRD="$(sudo find "$BOOT_MOUNT" -maxdepth 1 -type f -name 'initramfs-*.img' -printf '%f\n' | head -n1)"
ENTRY="$(sudo find "$BOOT_MOUNT/loader/entries" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | head -n1)"
[[ -n "$INITRD" && -n "$ENTRY" ]] || { echo "Could not locate Fedora boot files" >&2; exit 2; }
OPTIONS="$(sudo sed -n 's/^options //p' "$BOOT_MOUNT/loader/entries/$ENTRY" | head -n1)"
[[ -n "$OPTIONS" ]] || { echo "Could not obtain Fedora kernel options" >&2; exit 2; }

# Strip graphical/quiet modes and stale diagnostics inherited from Fedora.
# Boot-time experiments belong in separate GRUB entries so they can be changed
# without rebuilding the kernel. All A16 profiles keep Plymouth disabled.
read -r -a FEDORA_OPTIONS <<< "$OPTIONS"
FILTERED_OPTIONS=()
for option in "${FEDORA_OPTIONS[@]}"; do
  case "$option" in
    rhgb|quiet|splash|nomodeset|rd.plymouth=*|plymouth.*|loglevel=*|ignore_loglevel|initcall_debug|initcall_blacklist=msm_drm_register|deferred_probe_timeout=*|systemd.show_status=*|rd.systemd.show_status=*|rootwait|module_blacklist=*|modprobe.blacklist=*|rd.driver.blacklist=*) ;;
    *) FILTERED_OPTIONS+=("$option") ;;
  esac
done
BASE_OPTIONS="${FILTERED_OPTIONS[*]} rd.plymouth=0 plymouth.enable=0 rootwait"
NORMAL_OPTIONS="$BASE_OPTIONS"
DEBUG_OPTIONS="$BASE_OPTIONS loglevel=7 ignore_loglevel initcall_debug deferred_probe_timeout=30 systemd.show_status=1 rd.systemd.show_status=1"
FIRMWARE_FB_OPTIONS="$DEBUG_OPTIONS initcall_blacklist=msm_drm_register module_blacklist=msm modprobe.blacklist=msm rd.driver.blacklist=msm"

# A compressed cpio member may be concatenated to Fedora's stock initramfs.
# This preserves its known-good ARM64 userspace while making the latest Glymur
# firmware available before the real root filesystem is mounted.
A16_INITRD="initramfs-$VERSION-a16.img"
sudo cp "$BOOT_MOUNT/$INITRD" "$WORK/$A16_INITRD"
sudo chown "$(id -u):$(id -g)" "$WORK/$A16_INITRD"
(cd "$WORK/qcom-firmware" && find usr/lib/firmware -print0 \
  | cpio --null -o -H newc --quiet | gzip -9 >> "$WORK/$A16_INITRD")

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
  "Fedora Xfce - ASUS Zenbook A16 (normal, no splash)" "$NORMAL_OPTIONS"
write_bls_entry "$WORK/a16-debug.conf" \
  "Fedora Xfce - ASUS Zenbook A16 (debug logging)" "$DEBUG_OPTIONS"
write_bls_entry "$WORK/a16-firmware-fb.conf" \
  "Fedora Xfce - ASUS Zenbook A16 (firmware framebuffer, MSM DRM disabled)" "$FIRMWARE_FB_OPTIONS"
write_grub_entry "Fedora Xfce - ASUS Zenbook A16 (normal, no splash)" "$NORMAL_OPTIONS"
write_grub_entry "Fedora Xfce - ASUS Zenbook A16 (debug logging)" "$DEBUG_OPTIONS"
write_grub_entry "Fedora Xfce - ASUS Zenbook A16 (firmware framebuffer, MSM DRM disabled)" "$FIRMWARE_FB_OPTIONS"

sudo install -m 0644 "$STAGE/Image" "$BOOT_MOUNT/Image-$VERSION"
sudo install -m 0644 "$WORK/$A16_INITRD" "$BOOT_MOUNT/$A16_INITRD"
sudo cp -a "$STAGE/dtbs" "$BOOT_MOUNT/dtb-$VERSION"
sudo cp -a "$STAGE/modules/lib/modules/$VERSION" "$ROOT_MOUNT/usr/lib/modules/"
sudo depmod -b "$ROOT_MOUNT" "$VERSION"
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

# All filesystem writes must reach the raw backing file before it is compressed.
# Keeping the image mounted here previously produced an artifact with the
# pre-edit boot partition despite a successful workflow run.
echo "Flushing image filesystem changes"
sync
if sudo mountpoint -q "$BOOT_MOUNT"; then sudo umount "$BOOT_MOUNT"; fi
if sudo mountpoint -q "$ROOT_MOUNT"; then sudo umount "$ROOT_MOUNT"; fi
sudo losetup -d "$LOOP_DEV"
LOOP_DEV=""

FINAL="$OUT/fedora-xfce-a16-$VERSION.raw.xz"
echo "Compressing finished USB image"
pv -pterb -s "$(stat -c%s "$WORK/fedora-a16-xfce.raw")" "$WORK/fedora-a16-xfce.raw" | xz -T0 -1 > "$FINAL"
echo "Writing checksum and artifact parts"
sha256sum "$FINAL" > "$FINAL.sha256"
if [[ -n "${SPLIT_SIZE:-}" ]]; then
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  echo "Split image into $(basename "$FINAL").00.part, .01.part, ..."
fi
echo "Created: $FINAL"
