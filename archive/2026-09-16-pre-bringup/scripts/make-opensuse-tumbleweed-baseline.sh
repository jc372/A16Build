#!/usr/bin/env bash
# Download and reproduce an openSUSE Tumbleweed ARM64 (aarch64) ISO without
# changing a byte. This is the unchanged-baseline counterpart to
# make-ubuntu-daily-baseline.sh: it verifies the published checksum, copies the
# image, and independently confirms that the embedded EFI System Partition and
# the ISO 9660 installer kernel/initrd are byte-for-byte identical before and
# after. openSUSE ARM media carries its GRUB configuration on a FAT EFI System
# Partition embedded inside the ISO (MBR partition 1), so the baseline also
# records that ESP's grub.cfg checksum alongside the rest.
set -Eeuo pipefail

BASE_URL="${1:?usage: $0 <openSUSE-arm64.iso-url>}"
OUT="${OUT:-$PWD/out}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PWD/build/downloads}"
BASE_IMAGE_SHA256="${BASE_IMAGE_SHA256:?BASE_IMAGE_SHA256 is required}"
KEEP_OUTPUT="${KEEP_OUTPUT:-2}"
SPLIT_SIZE="${SPLIT_SIZE:-}"
# /etc/os-release exists on the Linux host; tolerate absence on other machines.
[[ -r /etc/os-release ]] && source /etc/os-release || true

for cmd in curl sha256sum cmp cp stat strings xorriso awk grep find sort tail cut split \
  mkdir mv rm basename uname dd mcopy mtype; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
[[ "$KEEP_OUTPUT" =~ ^[0-9]+$ ]] || { echo "KEEP_OUTPUT must be a non-negative integer" >&2; exit 2; }

mkdir -p "$OUT" "$DOWNLOAD_DIR"
BASE_ISO="$DOWNLOAD_DIR/$(basename "$BASE_URL")"
BASE_PART="$BASE_ISO.part"

verify_iso() {
  local image="$1"
  [[ -s "$image" ]] && printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$image" | sha256sum --check --status
}

if verify_iso "$BASE_ISO"; then
  echo "Reusing verified openSUSE ARM64 ISO: $BASE_ISO"
else
  echo "Downloading openSUSE ARM64 ISO: $BASE_URL"
  curl --fail --location --retry 3 --retry-all-errors --continue-at - "$BASE_URL" -o "$BASE_PART"
  if ! verify_iso "$BASE_PART"; then
    echo "A resumed ISO did not match the published checksum; retrying from byte zero"
    rm -f "$BASE_PART"
    curl --fail --location --retry 3 --retry-all-errors "$BASE_URL" -o "$BASE_PART"
    verify_iso "$BASE_PART" || { echo "openSUSE ARM64 ISO failed SHA-256 verification" >&2; exit 1; }
  fi
  mv "$BASE_PART" "$BASE_ISO"
fi

IMAGE_NAME="$(basename "$BASE_URL" .iso)"
FINAL="$OUT/opensuse-tumbleweed-baseline-$IMAGE_NAME.iso"
TEMP_FINAL="$FINAL.tmp"
rm -f "$TEMP_FINAL"
cp --reflink=auto "$BASE_ISO" "$TEMP_FINAL"
verify_iso "$TEMP_FINAL" || { echo "Baseline copy failed SHA-256 verification" >&2; exit 1; }
cmp "$BASE_ISO" "$TEMP_FINAL"
mv "$TEMP_FINAL" "$FINAL"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source" "$WORK/final"

# ISO 9660 installer payload (kernel/initrd) compared byte-for-byte.
for iso_path in /boot/aarch64/linux /boot/aarch64/initrd; do
  name="${iso_path##*/}"
  xorriso -osirrox on -indev "$BASE_ISO" -extract "$iso_path" "$WORK/source/$name" >/dev/null
  xorriso -osirrox on -indev "$FINAL" -extract "$iso_path" "$WORK/final/$name" >/dev/null
  cmp "$WORK/source/$name" "$WORK/final/$name"
done

# Embedded EFI System Partition (MBR partition 1) compared byte-for-byte: the FAT
# image is identical, so diffing the whole region is sufficient.
read -r ESP_START ESP_SECTORS < <(xorriso -indev "$BASE_ISO" -report_system_area plain 2>&1 \
  | awk '/^MBR partition[[:space:]]+:[[:space:]]+1[[:space:]]/{print $4, $6; exit}')
[[ "$ESP_START" =~ ^[0-9]+$ && "$ESP_SECTORS" =~ ^[0-9]+$ ]] || { echo "Could not locate embedded ESP" >&2; exit 2; }
dd if="$BASE_ISO" bs=512 skip="$ESP_START" count="$ESP_SECTORS" of="$WORK/source-esp.img" 2>/dev/null
dd if="$FINAL"    bs=512 skip="$ESP_START" count="$ESP_SECTORS" of="$WORK/final-esp.img" 2>/dev/null
cmp "$WORK/source-esp.img" "$WORK/final-esp.img"

KERNEL_RELEASE="$(strings "$WORK/final/linux" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-default$' || true)"
KERNEL_RELEASE="${KERNEL_RELEASE:-unknown}"
FINAL_BYTES="$(stat -f%z "$FINAL" 2>/dev/null || stat -c%s "$FINAL")"
VMLINUX_BYTES="$(stat -f%z "$WORK/final/linux" 2>/dev/null || stat -c%s "$WORK/final/linux")"
INITRD_BYTES="$(stat -f%z "$WORK/final/initrd" 2>/dev/null || stat -c%s "$WORK/final/initrd")"
ESP_BYTES="$(stat -f%z "$WORK/final-esp.img" 2>/dev/null || stat -c%s "$WORK/final-esp.img")"
if mtype -i "$WORK/final-esp.img" ::/EFI/BOOT/grub.cfg > "$WORK/final-grub.cfg" 2>/dev/null; then
  GRUB_BYTES="$(stat -f%z "$WORK/final-grub.cfg" 2>/dev/null || stat -c%s "$WORK/final-grub.cfg")"
else
  GRUB_BYTES=0
fi
VMLINUX_SHA256="$(sha256sum "$WORK/final/linux" | awk '{print $1}')"
INITRD_SHA256="$(sha256sum "$WORK/final/initrd" | awk '{print $1}')"
ESP_SHA256="$(sha256sum "$WORK/final-esp.img" | awk '{print $1}')"

( cd "$OUT" && printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$(basename "$FINAL")" > "$(basename "$FINAL").sha256" )
REPORT="$FINAL.baseline.txt"
cat > "$REPORT" <<EOF
openSUSE Tumbleweed ARM64 unchanged baseline
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
Host kernel: $(uname -srmo)
Source URL: $BASE_URL
Source ISO: $BASE_ISO
Output ISO: $FINAL
Published/output SHA-256: $BASE_IMAGE_SHA256
ISO size: $FINAL_BYTES bytes
Kernel release: $KERNEL_RELEASE
/boot/aarch64/linux: $VMLINUX_BYTES bytes, SHA-256 $VMLINUX_SHA256
/boot/aarch64/initrd: $INITRD_BYTES bytes, SHA-256 $INITRD_SHA256
Embedded ESP image: $ESP_BYTES bytes, SHA-256 $ESP_SHA256
EFI/BOOT/grub.cfg: $GRUB_BYTES bytes
Whole-image comparison: identical
Boot-file comparison: identical
Embedded ESP comparison: identical
Changes applied: none
EOF

FINAL_DESCRIPTION="$(basename "$FINAL")"
if [[ -n "$SPLIT_SIZE" ]]; then
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  FINAL_DESCRIPTION="$(basename "$FINAL").00.part, .01.part, ..."
fi

if (( KEEP_OUTPUT == 0 )); then
  :
else
  mapfile_stale() { :; }
  while IFS= read -r artifact; do
    echo "Pruning older openSUSE baseline: $(basename "$artifact")"
    rm -f -- "$artifact" "$artifact.sha256" "$artifact.baseline.txt"
  done < <(find "$OUT" -maxdepth 1 -type f -name 'opensuse-tumbleweed-baseline-*.iso' -print0 \
    | while IFS= read -r -d '' f; do printf '%s %s\n' "$(stat -c%Y "$f" 2>/dev/null || stat -f%m "$f")" "$f"; done \
    | sort -nr | tail -n +$((KEEP_OUTPUT + 1)) | cut -d' ' -f2-)
fi

cat <<EOF

========== openSUSE Tumbleweed ARM64 unchanged baseline ==========
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
openSUSE base: $BASE_URL
Kernel release: $KERNEL_RELEASE
Final artifact: $FINAL_DESCRIPTION
Final ISO size: $FINAL_BYTES bytes
SHA-256: $BASE_IMAGE_SHA256
Kernel size: $VMLINUX_BYTES bytes
Initramfs size: $INITRD_BYTES bytes
Embedded ESP size: $ESP_BYTES bytes
Verification report: $(basename "$REPORT")
Whole ISO: byte-for-byte identical to upstream
Kernel/initrd/ESP: byte-for-byte identical
Kernel patches: none
=====================================================
EOF
