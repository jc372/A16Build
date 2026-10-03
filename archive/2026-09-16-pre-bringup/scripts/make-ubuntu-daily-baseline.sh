#!/usr/bin/env bash
# Download and reproduce an Ubuntu ARM64 daily ISO without changing a byte.
set -Eeuo pipefail

BASE_URL="${1:?usage: $0 <ubuntu-desktop-arm64.iso-url>}"
OUT="${OUT:-$PWD/out}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PWD/build/downloads}"
BASE_IMAGE_SHA256="${BASE_IMAGE_SHA256:?BASE_IMAGE_SHA256 is required}"
KEEP_OUTPUT="${KEEP_OUTPUT:-2}"
SPLIT_SIZE="${SPLIT_SIZE:-}"
source /etc/os-release

for cmd in curl sha256sum cmp cp stat strings xorriso awk grep find sort tail cut split \
  mkdir mv rm basename uname; do
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
  echo "Reusing verified Ubuntu ARM64 daily ISO: $BASE_ISO"
else
  echo "Downloading Ubuntu ARM64 daily ISO: $BASE_URL"
  curl --fail --location --retry 3 --retry-all-errors --continue-at - "$BASE_URL" -o "$BASE_PART"
  if ! verify_iso "$BASE_PART"; then
    echo "A resumed ISO did not match the published checksum; retrying from byte zero"
    rm -f "$BASE_PART"
    curl --fail --location --retry 3 --retry-all-errors "$BASE_URL" -o "$BASE_PART"
    verify_iso "$BASE_PART" || { echo "Ubuntu daily ISO failed SHA-256 verification" >&2; exit 1; }
  fi
  mv "$BASE_PART" "$BASE_ISO"
fi

IMAGE_NAME="$(basename "$BASE_URL" .iso)"
FINAL="$OUT/ubuntu-baseline-$IMAGE_NAME.iso"
TEMP_FINAL="$FINAL.tmp"
rm -f "$TEMP_FINAL"
cp --reflink=auto "$BASE_ISO" "$TEMP_FINAL"
verify_iso "$TEMP_FINAL" || { echo "Baseline copy failed SHA-256 verification" >&2; exit 1; }
cmp "$BASE_ISO" "$TEMP_FINAL"
mv "$TEMP_FINAL" "$FINAL"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source" "$WORK/final"
for iso_path in /casper/vmlinuz /casper/initrd /boot/grub/grub.cfg; do
  name="${iso_path##*/}"
  xorriso -osirrox on -indev "$BASE_ISO" -extract "$iso_path" "$WORK/source/$name" >/dev/null
  xorriso -osirrox on -indev "$FINAL" -extract "$iso_path" "$WORK/final/$name" >/dev/null
  cmp "$WORK/source/$name" "$WORK/final/$name"
done

KERNEL_RELEASE="$(strings "$WORK/final/vmlinuz" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$' || true)"
KERNEL_RELEASE="${KERNEL_RELEASE:-unknown}"
FINAL_BYTES="$(stat -c%s "$FINAL")"
VMLINUX_BYTES="$(stat -c%s "$WORK/final/vmlinuz")"
INITRD_BYTES="$(stat -c%s "$WORK/final/initrd")"
GRUB_BYTES="$(stat -c%s "$WORK/final/grub.cfg")"
VMLINUX_SHA256="$(sha256sum "$WORK/final/vmlinuz" | awk '{print $1}')"
INITRD_SHA256="$(sha256sum "$WORK/final/initrd" | awk '{print $1}')"
GRUB_SHA256="$(sha256sum "$WORK/final/grub.cfg" | awk '{print $1}')"

(cd "$OUT" && printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$(basename "$FINAL")" > "$(basename "$FINAL").sha256")
REPORT="$FINAL.baseline.txt"
cat > "$REPORT" <<EOF
Ubuntu daily baseline verification
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
Host kernel: $(uname -srmo)
Source URL: $BASE_URL
Source ISO: $BASE_ISO
Output ISO: $FINAL
Published/output SHA-256: $BASE_IMAGE_SHA256
ISO size: $FINAL_BYTES bytes
Kernel release: $KERNEL_RELEASE
/casper/vmlinuz: $VMLINUX_BYTES bytes, SHA-256 $VMLINUX_SHA256
/casper/initrd: $INITRD_BYTES bytes, SHA-256 $INITRD_SHA256
/boot/grub/grub.cfg: $GRUB_BYTES bytes, SHA-256 $GRUB_SHA256
Whole-image comparison: identical
Boot-file comparison: identical
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
  mapfile -t stale < <(find "$OUT" -maxdepth 1 -type f -name 'ubuntu-baseline-*.iso' \
    -printf '%T@ %p\n' | sort -nr | tail -n +$((KEEP_OUTPUT + 1)) | cut -d' ' -f2-)
  for artifact in "${stale[@]}"; do
    echo "Pruning older Ubuntu baseline: $(basename "$artifact")"
    rm -f -- "$artifact" "$artifact.sha256" "$artifact.baseline.txt"
  done
fi

cat <<EOF

========== Ubuntu ARM64 unchanged baseline ==========
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
Ubuntu daily: $BASE_URL
Kernel release: $KERNEL_RELEASE
Final artifact: $FINAL_DESCRIPTION
Final ISO size: $FINAL_BYTES bytes
SHA-256: $BASE_IMAGE_SHA256
Kernel size: $VMLINUX_BYTES bytes
Initramfs size: $INITRD_BYTES bytes
GRUB config size: $GRUB_BYTES bytes
Verification report: $(basename "$REPORT")
Whole ISO: byte-for-byte identical to Canonical daily
Kernel/initrd/GRUB: byte-for-byte identical
Kernel patches: none
=====================================================
EOF
