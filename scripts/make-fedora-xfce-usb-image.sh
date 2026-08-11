#!/usr/bin/env bash
# Overlay a custom ARM64 kernel bundle on a Fedora Xfce ARM64 raw USB image.
set -Eeuo pipefail

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
BASE_URL="${2:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
OUT="${OUT:-$PWD/out}"
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

for cmd in curl xz tar awk lsblk losetup mount mountpoint partprobe pv udevadm sudo; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }; done
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

# Reuse Fedora's proven generic initramfs and root options. The custom Image and
# matching modules/DTB are added as a separate BLS menu entry; nothing becomes
# the default boot choice.
INITRD="$(sudo find "$BOOT_MOUNT" -maxdepth 1 -type f -name 'initramfs-*.img' -printf '%f\n' | head -n1)"
ENTRY="$(sudo find "$BOOT_MOUNT/loader/entries" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | head -n1)"
[[ -n "$INITRD" && -n "$ENTRY" ]] || { echo "Could not locate Fedora boot files" >&2; exit 2; }
OPTIONS="$(sudo sed -n 's/^options //p' "$BOOT_MOUNT/loader/entries/$ENTRY" | head -n1)"
[[ -n "$OPTIONS" ]] || { echo "Could not obtain Fedora kernel options" >&2; exit 2; }

cat > "$WORK/a16.conf" <<EOF
title Fedora Xfce - ASUS Zenbook A16 test kernel
version $VERSION
linux /Image-$VERSION
initrd /$INITRD
devicetree /$DTB_REL
options $OPTIONS
EOF

cat > "$WORK/a16-grub.cfg" <<EOF

menuentry 'Fedora Xfce - ASUS Zenbook A16 test kernel' {
    linux /Image-$VERSION $OPTIONS
    initrd /$INITRD
    devicetree /$DTB_REL
}
EOF

sudo install -m 0644 "$STAGE/Image" "$BOOT_MOUNT/Image-$VERSION"
sudo cp -a "$STAGE/dtbs" "$BOOT_MOUNT/dtb-$VERSION"
sudo cp -a "$STAGE/modules/lib/modules/$VERSION" "$ROOT_MOUNT/usr/lib/modules/"
sudo install -m 0644 "$WORK/a16.conf" "$BOOT_MOUNT/loader/entries/a16-$VERSION.conf"
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
