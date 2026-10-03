#!/usr/bin/env bash
# Replace the kernel payload in an official openSUSE Tumbleweed ARM64 (aarch64)
# DVD/installer ISO with the custom A16 kernel, matching Glymur DTB, the matching
# module tree, and the current Qualcomm/Atheros firmware.
#
# openSUSE ARM media is an isohybrid: the GRUB configuration lives on a FAT
# EFI System Partition that is embedded inside the ISO image (MBR partition 1),
# NOT inside the ISO 9660 file tree. The installer kernel and initrd live on the
# ISO 9660 tree at /boot/aarch64/linux and /boot/aarch64/initrd. This script
# therefore remasters the ISO 9660 payload with xorriso (replaying the boot
# record so the embedded ESP is preserved) and then rewrites the embedded ESP's
# grub.cfg with mtools so the A16 kernel and DTB are offered as first-class
# boot entries. It never writes a physical disk, alters UEFI/NVRAM, or touches
# the internal Windows boot chain.
set -Eeuo pipefail

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <openSUSE-arm64.iso>}"
BASE_ISO="${2:?usage: $0 <zenbook-a16-*.tar.zst> <openSUSE-arm64.iso>}"
OUT="${OUT:-$PWD/out}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ROOT/build/downloads}"
A16_FIRMWARE_DIR="$ROOT/firmware/qcom/glymur/ASUSTeK/UX3607OA"
BASE_IMAGE_SHA256="${BASE_IMAGE_SHA256:-}"
SPLIT_SIZE="${SPLIT_SIZE:-}"
source "$ROOT/config/build.env"
# /etc/os-release exists on the Linux host where this runs; on a foreign
# developer machine it may be absent, so tolerate its loss (PRETTY_NAME/ID fall
# through to defaults used by the summary).
[[ -r /etc/os-release ]] && source /etc/os-release || true
WORK="$(mktemp -d)"
# chmod first so the cleanup can remove root-owned cpio/firmware entries even on
# a non-root host (for example a macOS developer machine); harmless on Linux.
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'echo "openSUSE Tumbleweed ISO builder failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

# GNU cpio is required for initrd unpack/repack (the macOS/BSD cpio in $PATH on
# some hosts is not byte-compatible). Pick the GNU implementation explicitly,
# falling back to the keg-only Homebrew path or any gcpio alias before cpio.
CPIO=cpio
for candidate in gcpio /opt/homebrew/opt/cpio/bin/cpio /usr/local/opt/cpio/bin/cpio cpio; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version 2>&1 | grep -qi gnu; then
    CPIO="$candidate"; break
  fi
done

for cmd in curl sha256sum md5sum xorriso tar zstd "$CPIO" xz gzip rpm2cpio awk grep sed find sort cmp stat du dd mcopy mtype; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
mkdir -p "$OUT" "$DOWNLOAD_DIR"

# Hybrid ARM media may have an MBR partition extent beyond the ISO9660 payload.
# xorriso still extracts the requested files but reports SORRY (exit 32); later
# payload comparisons verify every extracted and remastered file we depend on.
xorriso_sorry_ok() {
  local rc
  if xorriso "$@"; then
    return 0
  else
    rc=$?
  fi
  [[ "$rc" -eq 0 || "$rc" -eq 32 ]] || return "$rc"
}

# --- Resolve the base ISO ----------------------------------------------------
# Accept either a local file path or an http(s) URL. When a URL is given the
# remote checksum, if supplied via BASE_IMAGE_SHA256, is enforced.
case "$BASE_ISO" in
  http://*|https://*)
    REMOTE=1
    BASE_NAME="$(basename "$BASE_ISO")"
    BASE_ISO_LOCAL="$DOWNLOAD_DIR/$BASE_NAME"
    BASE_PART="$BASE_ISO_LOCAL.part"
    if [[ -s "$BASE_ISO_LOCAL" ]] && { [[ -z "$BASE_IMAGE_SHA256" ]] || printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_ISO_LOCAL" | sha256sum --check --status; }; then
      echo "Reusing verified openSUSE base ISO: $BASE_ISO_LOCAL"
    else
      echo "Downloading openSUSE ARM64 base ISO: $BASE_ISO"
      curl --fail --location --retry 3 --retry-all-errors --continue-at - "$BASE_ISO" -o "$BASE_PART"
      if [[ -n "$BASE_IMAGE_SHA256" ]]; then
        printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_PART" | sha256sum --check --status || {
          rm -f "$BASE_PART"; echo "openSUSE base ISO failed SHA-256 verification" >&2; exit 1; }
      fi
      mv "$BASE_PART" "$BASE_ISO_LOCAL"
    fi
    BASE_ISO="$BASE_ISO_LOCAL"
    ;;
  *)
    REMOTE=0
    [[ -f "$BASE_ISO" ]] || { echo "Base ISO not found: $BASE_ISO" >&2; exit 2; }
    if [[ -n "$BASE_IMAGE_SHA256" ]]; then
      printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_ISO" | sha256sum --check --status || {
        echo "Base ISO failed SHA-256 verification" >&2; exit 1; }
    fi
    ;;
esac

# --- Unpack the A16 kernel bundle -------------------------------------------
mkdir -p "$WORK/bundle" "$WORK/iso-files" "$WORK/initrd-unpacked" "$WORK/initrd-root" "$WORK/esp"
tar --zstd -C "$WORK/bundle" -xf "$BUNDLE"
STAGE="$(find "$WORK/bundle" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$STAGE/Image" ]] || { echo "Invalid A16 kernel bundle" >&2; exit 2; }
VERSION="$(basename "$STAGE")"; VERSION="${VERSION#zenbook-a16-}"
DTB_SOURCE="$STAGE/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_ISO_PATH="/boot/aarch64/glymur-asus-zenbook-a16-ux3607oa.dtb"
[[ -f "$DTB_SOURCE" ]] || { echo "A16 DTB not found in kernel bundle" >&2; exit 2; }
KERNEL_CONFIG="$STAGE/metadata/kernel.config"
[[ -f "$KERNEL_CONFIG" ]] || { echo "Kernel bundle has no configuration metadata" >&2; exit 2; }
VA_BITS="$(awk -F= '$1 == "CONFIG_ARM64_VA_BITS" { print $2; exit }' "$KERNEL_CONFIG")"
[[ "$VA_BITS" =~ ^[0-9]+$ ]] || { echo "Kernel bundle has no valid CONFIG_ARM64_VA_BITS value" >&2; exit 2; }

# SNAPSHOT is derived from the base ISO filename when possible, for traceability.
BASE_NAME="$(basename "$BASE_ISO")"
if [[ "$BASE_NAME" =~ Snapshot([0-9]+) ]]; then
  SNAPSHOT="${BASH_REMATCH[1]}"
elif [[ "$BASE_NAME" =~ Current ]]; then
  SNAPSHOT="current"
else
  SNAPSHOT="$(printf '%s' "$BASE_NAME" | sed -E 's/[^A-Za-z0-9._-]/-/g')"
fi
BUILD_VARIANT="va${VA_BITS}-tumbleweed-${SNAPSHOT}-modular-drm-live-media"
MENU_BUILD="ASUS Zenbook A16 ${VA_BITS}-bit Tumbleweed ${SNAPSHOT} modular-DRM build $VERSION"

# --- Audit the kernel configuration (same early-boot set as the other builds) -
for requirement in CONFIG_EFI_STUB=y CONFIG_DRM_SIMPLEDRM=y CONFIG_SYSFB=y \
  CONFIG_SYSFB_SIMPLEFB=y CONFIG_FRAMEBUFFER_CONSOLE=y CONFIG_DRM_MSM=m \
  CONFIG_DRM_PANEL_EDP=m CONFIG_BLK_DEV_SR=y CONFIG_SCSI_VIRTIO=y CONFIG_ISO9660_FS=y \
  CONFIG_UDF_FS=y CONFIG_BLK_DEV_LOOP=y CONFIG_SQUASHFS=y \
  CONFIG_SQUASHFS_ZSTD=y CONFIG_OVERLAY_FS=y CONFIG_I2C_HID_ACPI=y \
  CONFIG_FW_LOADER_COMPRESS_XZ=y CONFIG_FW_LOADER_COMPRESS_ZSTD=y \
  CONFIG_ATH12K=m CONFIG_MHI_BUS=m CONFIG_QRTR_MHI=m; do
  grep -qxF "$requirement" "$KERNEL_CONFIG" || {
    echo "Kernel bundle is missing $requirement; rebuild kernel and image with 'run-wsl-build.sh both'" >&2
    exit 2
  }
done
grep -qxF "# CONFIG_FB_EFI is not set" "$KERNEL_CONFIG" || {
  echo "Kernel bundle must leave CONFIG_FB_EFI disabled for the simpledrm handoff" >&2
  exit 2
}

# --- Pull the current Qualcomm + Atheros firmware RPMs (reused from build.env) -
# Each call returns the cached RPM path. A previously cached file is reused only
# after a full extraction proves it is intact; otherwise it is removed and
# re-downloaded from byte zero (resuming a truncated transfer is rejected so a
# killed run cannot leave a half-written RPM that later validates).
fetch_firmware_rpm() {
  local base_url="$1" pattern="$2" expect="$3"
  local latest cache part tmp
  latest="$(curl --fail --location --retry 3 "$base_url/" | grep -oE "$pattern" | sort -Vu | tail -n1)"
  [[ -n "$latest" ]] || { echo "Could not locate $pattern" >&2; exit 2; }
  cache="$DOWNLOAD_DIR/$latest"
  part="$cache.part"
  rpm_is_intact() {
    local rpm="$1" tmp
    tmp="$(mktemp -d)"
    rpm2cpio "$rpm" 2>/dev/null | "$CPIO" -idm --no-preserve-owner --quiet -D "$tmp" >/dev/null 2>&1 \
      && [[ -d "$tmp/$expect" ]]
    local rc=$?
    rm -rf "$tmp"
    return $rc
  }
  if [[ -s "$cache" ]] && rpm_is_intact "$cache"; then
    echo "Reusing cached firmware RPM: $latest" >&2
  else
    rm -f "$cache" "$part"
    echo "Downloading firmware RPM: $latest" >&2
    curl --fail --location --retry 3 --retry-all-errors -o "$part" "$base_url/$latest"
    rpm_is_intact "$part" || { rm -f "$part"; echo "Downloaded firmware RPM is invalid or incomplete" >&2; exit 1; }
    mv "$part" "$cache"
  fi
  printf '%s\n' "$cache"
}
QCOM_RPM="$(fetch_firmware_rpm "$QCOM_FIRMWARE_BASE_URL" 'qcom-firmware-[^"<]+\.noarch\.rpm' usr/lib/firmware/qcom)"
ATHEROS_RPM="$(fetch_firmware_rpm "$ATHEROS_FIRMWARE_BASE_URL" 'atheros-firmware-[^"<]+\.noarch\.rpm' usr/lib/firmware/ath12k)"
mkdir -p "$WORK/qcom-firmware" "$WORK/atheros-firmware"
( cd "$WORK/qcom-firmware" && rpm2cpio "$QCOM_RPM" | "$CPIO" -idm --no-preserve-owner --quiet )
( cd "$WORK/atheros-firmware" && rpm2cpio "$ATHEROS_RPM" | "$CPIO" -idm --no-preserve-owner --quiet )
[[ -d "$WORK/atheros-firmware/usr/lib/firmware/ath12k/WCN7850" ]] || {
  echo "Downloaded Atheros RPM has no WCN7850 firmware tree" >&2; exit 2; }

# --- Rebuild the openSUSE installer initramfs with the custom module tree -----
echo "Extracting openSUSE installer kernel and initramfs"
for firmware in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf; do
  [[ -f "$A16_FIRMWARE_DIR/$firmware" ]] || {
    echo "Missing checked-in A16 firmware: $A16_FIRMWARE_DIR/$firmware" >&2
    exit 2
  }
done

xorriso_sorry_ok -osirrox on -indev "$BASE_ISO" \
  -extract /boot/aarch64/linux "$WORK/iso-files/linux" \
  -extract /boot/aarch64/initrd "$WORK/iso-files/initrd" >/dev/null
# Keep the original installer initrd for size comparison / diagnostics.
BASE_INITRD_BYTES="$(stat -f%z "$WORK/iso-files/initrd" 2>/dev/null || stat -c%s "$WORK/iso-files/initrd")"

echo "Rebuilding openSUSE initramfs for custom kernel $VERSION"
# The installer initrd carries /dev device nodes; on a host where cpio cannot
# mknod (for example a non-root macOS developer machine) those extractions fail
# but are harmless -- the repack below rebuilds the initramfs from a filtered
# tree that never references /dev. Tolerate the mknod errors so the build still
# completes; on Linux (root or fakeroot) the nodes extract and are preserved.
set +o pipefail
xz -dc "$WORK/iso-files/initrd" 2>/dev/null | ( cd "$WORK/initrd-unpacked" && "$CPIO" -idm --no-preserve-owner --quiet 2>/dev/null ) || true
set -o pipefail
rm -rf "$WORK/initrd-root"; mkdir -p "$WORK/initrd-root/usr/lib/modules" "$WORK/initrd-root/usr/lib/firmware"
( cd "$WORK/initrd-unpacked" && find . -print0 | sort -z | "$CPIO" --null -o -H newc --owner=0:0 --quiet 2>/dev/null ) \
  | ( cd "$WORK/initrd-root" && "$CPIO" -idm --no-preserve-owner --quiet 2>/dev/null ) || true
rm -rf "$WORK/initrd-root/usr/lib/modules"/*
mkdir -p "$WORK/initrd-root/usr/lib/modules" "$WORK/initrd-root/usr/lib/firmware"
cp -a "$STAGE/modules/lib/modules/$VERSION" "$WORK/initrd-root/usr/lib/modules/"
cp -a "$WORK/qcom-firmware/usr/lib/firmware/." "$WORK/initrd-root/usr/lib/firmware/"
cp -a "$WORK/atheros-firmware/usr/lib/firmware/." "$WORK/initrd-root/usr/lib/firmware/"
mkdir -p "$WORK/initrd-root/usr/lib/firmware/qcom/glymur/ASUSTeK"
cp -a "$A16_FIRMWARE_DIR" "$WORK/initrd-root/usr/lib/firmware/qcom/glymur/ASUSTeK/"
( cd "$WORK/initrd-root" && find . -print0 | sort -z | "$CPIO" --null -o -H newc --owner=0:0 --quiet | xz -9 > "$WORK/a16-initrd" )

# The openSUSE installer root is provided by the squashfs layers on the ISO; the
# custom module tree and Qualcomm firmware live in the initramfs so the installer
# can load qcom storage/network drivers. Mirror the tree onto the ISO 9660 tree as
# well so the installed system and the rescue entry can reach them.
mkdir -p "$WORK/iso-extra/boot/aarch64/modules" "$WORK/iso-extra/boot/aarch64/firmware"
cp -a "$STAGE/modules/lib/modules/$VERSION" "$WORK/iso-extra/boot/aarch64/modules/"
cp -a "$WORK/qcom-firmware/usr/lib/firmware/." "$WORK/iso-extra/boot/aarch64/firmware/"
cp -a "$WORK/atheros-firmware/usr/lib/firmware/." "$WORK/iso-extra/boot/aarch64/firmware/"
mkdir -p "$WORK/iso-extra/boot/aarch64/firmware/qcom/glymur/ASUSTeK"
cp -a "$A16_FIRMWARE_DIR" "$WORK/iso-extra/boot/aarch64/firmware/qcom/glymur/ASUSTeK/"

INITRD_KERNEL_RELEASES=()
while IFS= read -r dir; do
  INITRD_KERNEL_RELEASES+=("$(basename "$dir")")
done < <(find "$WORK/initrd-root/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#INITRD_KERNEL_RELEASES[@]} -eq 1 && "${INITRD_KERNEL_RELEASES[0]}" == "$VERSION" ]] || {
  printf 'Expected only initramfs kernel release %s; found: %s\n' "$VERSION" "${INITRD_KERNEL_RELEASES[*]:-none}" >&2
  exit 1
}

# --- Remaster the ISO 9660 tree (kernel, initrd, DTB, extra firmware) ----------
# openSUSE ARM media is an isohybrid: the bootloader lives in an embedded FAT
# EFI System Partition, whose image is the El Torito boot file at
# /boot/aarch64/efi inside the ISO 9660 tree. For a UEFI (EFI) boot -- which is
# what the A16 uses -- the firmware loads that El Torito image, so modifying the
# ESP's grub.cfg and mapping the *already modified* ESP as /boot/aarch64/efi is
# sufficient and avoids depending on xorriso to re-establish the MBR isohybrid
# partition table (which it reports as a non-fatal SORRY 32).
FINAL="$OUT/opensuse-tumbleweed-a16-$VERSION-$BUILD_VARIANT.iso"
rm -f "$FINAL"

echo "Extracting and rewriting the openSUSE EFI System Partition GRUB configuration"
xorriso_sorry_ok -osirrox on -indev "$BASE_ISO" -extract /boot/aarch64/efi "$WORK/esp.img" >/dev/null
# The extracted ESP image may be root-owned (its archive entries are); ensure we
# can rewrite it. Harmless on a root/Linux host.
chmod u+rw "$WORK/esp.img" 2>/dev/null || true
ESP_GRUBCFG="$WORK/esp-grub.cfg"
mtype -i "$WORK/esp.img" ::/EFI/BOOT/grub.cfg > "$ESP_GRUBCFG" 2>/dev/null \
  || { echo "Could not read the source ESP grub.cfg" >&2; exit 2; }

DIAGNOSTIC_OPTIONS="console=tty0 earlycon keep_bootcon loglevel=8 ignore_loglevel initcall_debug systemd.show_status=1 rd.systemd.show_status=1 plymouth.enable=0 systemd.unit=multi-user.target panic=0 module_blacklist=msm modprobe.blacklist=msm"
# Preserve every stock openSUSE entry verbatim, then append the A16 profiles.
A16_ENTRIES_FILE="$WORK/a16-entries.cfg"
cat > "$A16_ENTRIES_FILE" <<EOF

# === A16 (ASUS Zenbook A16 / Glymur) custom-kernel entries ===================
set a16_linux=/boot/aarch64/linux
set a16_initrd=/boot/aarch64/initrd
set a16_dtb=/boot/aarch64/glymur-asus-zenbook-a16-ux3607oa.dtb

menuentry '$MENU_BUILD - DTB installation' --class opensuse --class gnu-linux --class gnu --class os {
  set gfxpayload=keep
  echo 'Loading A16 kernel ...'
  linux \$a16_linux splash=silent acpi=off \$platform_cmdline $DIAGNOSTIC_OPTIONS
  devicetree \$a16_dtb
  echo 'Loading A16 initial ramdisk ...'
  initrd \$a16_initrd
}

menuentry '$MENU_BUILD - DTB rescue system' --class opensuse --class gnu-linux --class gnu {
  set gfxpayload=keep
  echo 'Loading A16 kernel ...'
  linux \$a16_linux splash=silent acpi=off rescue=1 \$platform_cmdline $DIAGNOSTIC_OPTIONS
  devicetree \$a16_dtb
  initrd \$a16_initrd
}

menuentry '$MENU_BUILD - ACPI installation' --class opensuse --class gnu-linux --class gnu --class os {
  set gfxpayload=keep
  echo 'Loading A16 kernel ...'
  linux \$a16_linux splash=silent acpi=force \$platform_cmdline $DIAGNOSTIC_OPTIONS
  echo 'Loading A16 initial ramdisk ...'
  initrd \$a16_initrd
}
EOF

if grep -q "hiddenentry 'Text mode'" "$ESP_GRUBCFG"; then
  awk -v inc="$WORK/a16-entries.cfg" '
    /hiddenentry .Text mode./ { while ((getline line < inc) > 0) print line; close(inc); print; next }
    { print }
  ' "$ESP_GRUBCFG" > "$WORK/esp-grub-new.cfg"
else
  cat "$ESP_GRUBCFG" "$WORK/a16-entries.cfg" > "$WORK/esp-grub-new.cfg"
fi
mcopy -o -i "$WORK/esp.img" "$WORK/esp-grub-new.cfg" ::/EFI/BOOT/grub.cfg

echo "Writing custom openSUSE Tumbleweed A16 installer ISO"
set +e
xorriso -indev "$BASE_ISO" -outdev "$FINAL" -boot_image any replay \
  -map "$WORK/esp.img" /boot/aarch64/efi \
  -map "$STAGE/Image" /boot/aarch64/linux \
  -map "$WORK/a16-initrd" /boot/aarch64/initrd \
  -map "$DTB_SOURCE" "$DTB_ISO_PATH" \
  -map "$WORK/iso-extra/boot/aarch64/modules/$VERSION" "/boot/aarch64/modules/$VERSION" \
  -map "$WORK/iso-extra/boot/aarch64/firmware/qcom" /boot/aarch64/firmware/qcom \
  -map "$WORK/iso-extra/boot/aarch64/firmware/ath12k" /boot/aarch64/firmware/ath12k \
  -commit >/dev/null
XORRISO_RC=$?
set -e
# xorriso reports SORRY 32 when it re-assesses the isohybrid even though the
# image was written; the modified ESP is carried as the El Torito /boot/aarch64/efi
# image above, so treat a SORRY-only exit as success. Any other non-zero exit is
# a real failure.
[[ "$XORRISO_RC" -eq 0 || "$XORRISO_RC" -eq 32 ]] || {
  echo "xorriso remaster failed (exit $XORRISO_RC)" >&2; exit 1; }

# --- Verify the remastered image --------------------------------------------
mkdir -p "$WORK/verify"
xorriso_sorry_ok -osirrox on -indev "$FINAL" \
  -extract /boot/aarch64/linux "$WORK/verify/linux" \
  -extract /boot/aarch64/initrd "$WORK/verify/initrd" \
  -extract "$DTB_ISO_PATH" "$WORK/verify/a16.dtb" \
  -extract /boot/aarch64/efi "$WORK/verify/efi" >/dev/null
cmp "$STAGE/Image" "$WORK/verify/linux"
cmp "$DTB_SOURCE" "$WORK/verify/a16.dtb"
"$CPIO" -it < <(xz -dc "$WORK/verify/initrd") > "$WORK/initramfs-listing.txt" 2>/dev/null
grep -q "usr/lib/modules/$VERSION" "$WORK/initramfs-listing.txt"
grep -q "usr/lib/firmware/qcom" "$WORK/initramfs-listing.txt"
grep -q "usr/lib/firmware/ath12k/WCN7850" "$WORK/initramfs-listing.txt"

# Confirm the A16 entries landed in the remastered ESP's grub.cfg.
mtype -i "$WORK/verify/efi" ::/EFI/BOOT/grub.cfg > "$WORK/verify-grub.cfg" 2>/dev/null \
  || { echo "Could not read the remastered ESP grub.cfg" >&2; exit 2; }
grep -qF "DTB installation" "$WORK/verify-grub.cfg"
grep -qF "devicetree \$a16_dtb" "$WORK/verify-grub.cfg"
grep -qF "ACPI installation" "$WORK/verify-grub.cfg"
grep -qF "$MENU_BUILD" "$WORK/verify-grub.cfg"

( cd "$(dirname "$FINAL")" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256" )
( cd "$(dirname "$FINAL")" && sha256sum --check "$(basename "$FINAL").sha256" )
FINAL_BYTES="$(stat -f%z "$FINAL" 2>/dev/null || stat -c%s "$FINAL")"
if [[ -n "$SPLIT_SIZE" ]]; then
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  FINAL_DESCRIPTION="$(basename "$FINAL").00.part, .01.part, ..."
else
  FINAL_DESCRIPTION="$(basename "$FINAL")"
fi

cat <<EOF

========== A16 openSUSE Tumbleweed live ISO build summary ==========
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
Host kernel: $(uname -srmo)
Kernel release: $VERSION
Kernel address size: ${VA_BITS}-bit VA/PA test
Base ISO: $BASE_ISO
Snapshot: $SNAPSHOT
Qualcomm firmware RPM: $(basename "$QCOM_RPM")
Atheros firmware RPM: $(basename "$ATHEROS_RPM")
Custom Image: $(stat -f%z "$STAGE/Image" 2>/dev/null || stat -c%s "$STAGE/Image") bytes
Custom initramfs: $(stat -f%z "$WORK/a16-initrd" 2>/dev/null || stat -c%s "$WORK/a16-initrd") bytes (base installer initrd was $BASE_INITRD_BYTES bytes)
A16 DTB: $(stat -f%z "$DTB_SOURCE" 2>/dev/null || stat -c%s "$DTB_SOURCE") bytes
Custom module tree: $(du -sk "$STAGE/modules/lib/modules/$VERSION" 2>/dev/null | awk '{print $1*1024}') bytes
Final artifact: $FINAL_DESCRIPTION
Final ISO size before splitting: $FINAL_BYTES bytes
Checksum: $(basename "$FINAL").sha256
Live boot payload: custom A16 kernel, DTB, modules, and Qualcomm firmware
Default boot path: DTB installation with MSM DRM suppressed
Alternate boot paths: DTB rescue system, ACPI installation
Note: the installer uses the custom kernel; the openSUSE installer may still
install Tumbleweed's packaged kernel into the permanent target until
custom-kernel installation is added.
=======================================================
EOF
