#!/usr/bin/env bash
# Overlay a custom ARM64 kernel bundle on a Fedora Xfce ARM64 raw USB image.
set -Eeuo pipefail

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
BASE_URL="${2:?usage: $0 <zenbook-a16-*.tar.zst> <fedora-raw.xz-url>}"
OUT="${OUT:-$PWD/out}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for cmd in curl xz tar guestfish awk; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }; done
mkdir -p "$OUT"

echo "Downloading Fedora Xfce ARM64 base image"
curl --fail --location --retry 3 "$BASE_URL" -o "$WORK/fedora.raw.xz"
xz -T0 -d -c "$WORK/fedora.raw.xz" > "$WORK/fedora-a16-xfce.raw"

mkdir "$WORK/bundle"
tar --zstd -C "$WORK/bundle" -xf "$BUNDLE"
STAGE="$(find "$WORK/bundle" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$STAGE/Image" ]] || { echo "Invalid kernel bundle" >&2; exit 2; }
VERSION="$(basename "$STAGE")"; VERSION="${VERSION#zenbook-a16-}"
DTB_REL="dtb-$VERSION/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
[[ -f "$STAGE/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb" ]] || {
  echo "A16 DTB not found in kernel bundle" >&2; exit 2;
}

# Reuse Fedora's proven generic initramfs and root options. The custom Image and
# matching modules/DTB are added as a separate BLS menu entry; nothing becomes
# the default boot choice.
BOOT_LIST="$(guestfish --ro -a "$WORK/fedora-a16-xfce.raw" -i ls /boot)"
INITRD="$(printf '%s\n' "$BOOT_LIST" | awk '/^initramfs-.*\.img$/{print; exit}')"
ENTRY="$(guestfish --ro -a "$WORK/fedora-a16-xfce.raw" -i ls /boot/loader/entries | awk '/\.conf$/{print; exit}')"
[[ -n "$INITRD" && -n "$ENTRY" ]] || { echo "Could not locate Fedora boot files" >&2; exit 2; }
OPTIONS="$(guestfish --ro -a "$WORK/fedora-a16-xfce.raw" -i cat "/boot/loader/entries/$ENTRY" | sed -n 's/^options //p' | head -n1)"
[[ -n "$OPTIONS" ]] || { echo "Could not obtain Fedora kernel options" >&2; exit 2; }

cat > "$WORK/a16.conf" <<EOF
title Fedora Xfce — ASUS Zenbook A16 test kernel
version $VERSION
linux /Image-$VERSION
initrd /$INITRD
devicetree /$DTB_REL
options $OPTIONS
EOF

guestfish --rw -a "$WORK/fedora-a16-xfce.raw" -i <<EOF
copy-in $STAGE/Image /boot
mv /boot/Image /boot/Image-$VERSION
copy-in $STAGE/dtbs /boot
mv /boot/dtbs /boot/dtb-$VERSION
copy-in $STAGE/modules/lib/modules/$VERSION /usr/lib/modules
copy-in $WORK/a16.conf /boot/loader/entries
mv /boot/loader/entries/a16.conf /boot/loader/entries/a16-$VERSION.conf
EOF

FINAL="$OUT/fedora-xfce-a16-$VERSION.raw.xz"
xz -T0 -c "$WORK/fedora-a16-xfce.raw" > "$FINAL"
sha256sum "$FINAL" > "$FINAL.sha256"
if [[ -n "${SPLIT_SIZE:-}" ]]; then
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  echo "Split image into $(basename "$FINAL").00.part, .01.part, ..."
fi
echo "Created: $FINAL"
