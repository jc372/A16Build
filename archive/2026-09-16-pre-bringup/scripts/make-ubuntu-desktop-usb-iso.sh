#!/usr/bin/env bash
# Replace the kernel payload in an official Ubuntu ARM64 desktop live ISO.
set -Eeuo pipefail

BUNDLE="${1:?usage: $0 <zenbook-a16-*.tar.zst> <ubuntu-desktop-arm64.iso-url>}"
BASE_URL="${2:?usage: $0 <zenbook-a16-*.tar.zst> <ubuntu-desktop-arm64.iso-url>}"
OUT="${OUT:-$PWD/out}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ROOT/build/downloads}"
BASE_IMAGE_SHA256="${BASE_IMAGE_SHA256:-}"
SPLIT_SIZE="${SPLIT_SIZE:-}"
source "$ROOT/config/build.env"
source /etc/os-release
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'echo "Ubuntu ISO builder failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

for cmd in curl sha256sum md5sum xorriso tar zstd unmkinitramfs cpio gzip rpm2cpio awk grep sed find sort cmp stat du; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 2; }
done
mkdir -p "$OUT" "$DOWNLOAD_DIR"

BASE_ISO="$DOWNLOAD_DIR/$(basename "$BASE_URL")"
BASE_PART="$BASE_ISO.part"
verify_base_iso() {
  [[ -s "$BASE_ISO" ]] || return 1
  [[ -z "$BASE_IMAGE_SHA256" ]] || printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_ISO" | sha256sum --check --status
}

if verify_base_iso; then
  echo "Reusing verified Ubuntu ARM64 daily ISO: $BASE_ISO"
else
  echo "Downloading Ubuntu ARM64 daily ISO"
  curl --fail --location --retry 3 --retry-all-errors --continue-at - "$BASE_URL" -o "$BASE_PART"
  if [[ -n "$BASE_IMAGE_SHA256" ]]; then
    if ! printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_PART" | sha256sum --check --status; then
      echo "A resumed ISO did not match the current daily checksum; retrying from byte zero"
      rm -f "$BASE_PART"
      curl --fail --location --retry 3 --retry-all-errors "$BASE_URL" -o "$BASE_PART"
      printf '%s  %s\n' "$BASE_IMAGE_SHA256" "$BASE_PART" | sha256sum --check --status || {
        echo "Ubuntu daily ISO failed SHA-256 verification" >&2; exit 1;
      }
    fi
  fi
  mv "$BASE_PART" "$BASE_ISO"
fi

mkdir -p "$WORK/bundle" "$WORK/iso-files" "$WORK/initrd-unpacked" "$WORK/initrd-root"
tar --zstd -C "$WORK/bundle" -xf "$BUNDLE"
STAGE="$(find "$WORK/bundle" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$STAGE/Image" ]] || { echo "Invalid A16 kernel bundle" >&2; exit 2; }
VERSION="$(basename "$STAGE")"; VERSION="${VERSION#zenbook-a16-}"
DTB_SOURCE="$STAGE/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
DTB_ISO_PATH="/casper/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
[[ -f "$DTB_SOURCE" ]] || { echo "A16 DTB not found in kernel bundle" >&2; exit 2; }
# DTB_OVERRIDE=<file> replaces the bundle's device tree for this image. Used to
# test a post-processed DTB (for example one with a /memory node added from the
# harvested memory map) without rebuilding the kernel.
if [[ -n "${DTB_OVERRIDE:-}" ]]; then
  [[ -f "$DTB_OVERRIDE" ]] || { echo "DTB_OVERRIDE not found: $DTB_OVERRIDE" >&2; exit 2; }
  DTB_SOURCE="$DTB_OVERRIDE"
  echo "Using DTB override: $DTB_SOURCE"
fi
KERNEL_CONFIG="$STAGE/metadata/kernel.config"
[[ -f "$KERNEL_CONFIG" ]] || { echo "Kernel bundle has no configuration metadata" >&2; exit 2; }
VA_BITS="$(awk -F= '$1 == "CONFIG_ARM64_VA_BITS" { print $2; exit }' "$KERNEL_CONFIG")"
[[ "$VA_BITS" =~ ^[0-9]+$ ]] || { echo "Kernel bundle has no valid CONFIG_ARM64_VA_BITS value" >&2; exit 2; }
UBUNTU_SERIES="$(basename "$BASE_URL")"
UBUNTU_SERIES="${UBUNTU_SERIES%-desktop-arm64.iso}"
BUILD_VARIANT="va${VA_BITS}-${UBUNTU_SERIES}-modular-drm-live-media${VARIANT_SUFFIX:-}"
MENU_BUILD="ASUS Zenbook A16 ${VA_BITS}-bit ${UBUNTU_SERIES^} modular-DRM live-media build $VERSION"
for requirement in CONFIG_EFI_STUB=y CONFIG_DRM_SIMPLEDRM=y CONFIG_SYSFB=y \
  CONFIG_SYSFB_SIMPLEFB=y CONFIG_FRAMEBUFFER_CONSOLE=y CONFIG_DRM_MSM=m \
  CONFIG_DRM_PANEL_EDP=m CONFIG_BLK_DEV_SR=y CONFIG_SCSI_VIRTIO=y CONFIG_ISO9660_FS=y \
  CONFIG_UDF_FS=y CONFIG_BLK_DEV_LOOP=y CONFIG_SQUASHFS=y \
  CONFIG_SQUASHFS_ZSTD=y CONFIG_OVERLAY_FS=y CONFIG_I2C_HID_ACPI=y \
  CONFIG_FW_LOADER_COMPRESS_XZ=y CONFIG_FW_LOADER_COMPRESS_ZSTD=y \
  CONFIG_ATH12K=m CONFIG_MHI_BUS=m CONFIG_QRTR_MHI=m; do
  # Presence check: =m is accepted wherever the requirement asked for =y,
  # because the rebuilt initramfs carries the complete module tree for the
  # shipped kernel, so the live-media path comes up from modules exactly as the
  # distribution's own live ISO does. Requirements stated as =m stay exact.
  symbol="${requirement%%=*}"; want="${requirement#*=}"
  if [[ "$want" == y ]]; then
    grep -qE "^${symbol}=(y|m)$" "$KERNEL_CONFIG" || {
      echo "Kernel bundle is missing ${symbol}=y|m; rebuild kernel and image with 'run-wsl-build.sh both'" >&2
      exit 2
    }
  else
    grep -qxF "$requirement" "$KERNEL_CONFIG" || {
      echo "Kernel bundle is missing $requirement; rebuild kernel and image with 'run-wsl-build.sh both'" >&2
      exit 2
    }
  fi
done
grep -qxF "# CONFIG_FB_EFI is not set" "$KERNEL_CONFIG" || {
  echo "Kernel bundle must leave CONFIG_FB_EFI disabled for the simpledrm handoff" >&2
  exit 2
}

echo "Extracting Ubuntu live-boot files"
xorriso -osirrox on -indev "$BASE_ISO" \
  -extract /casper/initrd "$WORK/iso-files/initrd" \
  -extract /boot/grub/grub.cfg "$WORK/iso-files/grub.cfg" \
  -extract /md5sum.txt "$WORK/iso-files/md5sum.txt" >/dev/null
# Optional same-media control: keep the stock Ubuntu kernel and initramfs on the
# image under .stock names. The custom kernel replaces /casper/vmlinuz, so
# without this a USB stick cannot distinguish "custom kernel is broken" from
# "medium/handoff is broken" without a second flash. Adds ~170 MB.
STOCK_ENTRIES="${STOCK_ENTRIES:-0}"
STOCK_MAPS=()
if [[ "$STOCK_ENTRIES" == 1 ]]; then
  xorriso -osirrox on -indev "$BASE_ISO" -extract /casper/vmlinuz "$WORK/iso-files/vmlinuz" >/dev/null
  [[ -s "$WORK/iso-files/vmlinuz" ]] || { echo "Could not extract the stock Ubuntu kernel" >&2; exit 2; }
  STOCK_MAPS=(-map "$WORK/iso-files/vmlinuz" /casper/vmlinuz.stock
              -map "$WORK/iso-files/initrd" /casper/initrd.stock)
fi

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
  curl --fail --location --retry 3 --retry-all-errors --continue-at - \
    "$QCOM_FIRMWARE_BASE_URL/$QCOM_FIRMWARE_RPM" -o "$QCOM_FIRMWARE_PART"
  rpm2cpio "$QCOM_FIRMWARE_PART" | cpio -it --quiet >/dev/null || {
    echo "Downloaded Qualcomm firmware RPM is invalid" >&2; exit 1;
  }
  mv "$QCOM_FIRMWARE_PART" "$QCOM_FIRMWARE_CACHE"
fi
mkdir -p "$WORK/qcom-firmware"
(cd "$WORK/qcom-firmware" && rpm2cpio "$QCOM_FIRMWARE_CACHE" | cpio -idm --quiet)

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
    echo "Downloaded Atheros firmware RPM is invalid" >&2; exit 1;
  }
  mv "$ATHEROS_FIRMWARE_PART" "$ATHEROS_FIRMWARE_CACHE"
fi
mkdir -p "$WORK/atheros-firmware"
(cd "$WORK/atheros-firmware" && rpm2cpio "$ATHEROS_FIRMWARE_CACHE" | cpio -idm --quiet)
[[ -d "$WORK/atheros-firmware/usr/lib/firmware/ath12k/WCN7850" ]] || {
  echo "Downloaded Atheros RPM has no WCN7850 firmware tree" >&2; exit 2;
}

echo "Rebuilding Ubuntu initramfs for custom kernel $VERSION"
unmkinitramfs "$WORK/iso-files/initrd" "$WORK/initrd-unpacked"
shopt -s nullglob
layers=()
if [[ -f "$WORK/initrd-unpacked/init" ]]; then
  # Current initramfs-tools extracts a single archive directly into the target.
  layers+=("$WORK/initrd-unpacked")
else
  # Older/multi-archive initrds are exposed as early*, then main directories.
  for layer in "$WORK/initrd-unpacked"/early* "$WORK/initrd-unpacked"/main; do
    [[ -d "$layer" ]] && layers+=("$layer")
  done
fi
[[ ${#layers[@]} -gt 0 ]] || { echo "Could not identify unpacked Ubuntu initramfs contents" >&2; exit 2; }
for layer in "${layers[@]}"; do cp -a "$layer/." "$WORK/initrd-root/"; done
rm -rf "$WORK/initrd-root/lib/modules" "$WORK/initrd-root/usr/lib/modules"
mkdir -p "$WORK/initrd-root/usr/lib/modules" "$WORK/initrd-root/usr/lib/firmware"
cp -a "$STAGE/modules/lib/modules/$VERSION" "$WORK/initrd-root/usr/lib/modules/"
cp -a "$WORK/qcom-firmware/usr/lib/firmware/." "$WORK/initrd-root/usr/lib/firmware/"
cp -a "$WORK/atheros-firmware/usr/lib/firmware/." "$WORK/initrd-root/usr/lib/firmware/"

# Harvest hook (A16_HARVEST=1): carry the bring-up collector in the initramfs so
# the local-bottom hook can install it into the live root. The A16 has no
# usable internal keyboard/touchpad in ACPI mode, so a live session cannot be
# interrogated by hand; this makes every boot report its own device state.
A16_HARVEST="${A16_HARVEST:-0}"
# Wall-clock delay before the harvest unit fires (systemd OnBootSec). 90 s is
# past udev settling on real hardware and independent of how long the
# multi-user transaction takes.
A16_HARVEST_DELAY="${A16_HARVEST_DELAY:-90}"
mkdir -p "$WORK/initrd-root/usr/local/sbin"
if [[ "$A16_HARVEST" == 1 ]]; then
  install -m 0755 "$ROOT/scripts/a16-harvest.sh" "$WORK/initrd-root/usr/local/sbin/a16-harvest"
fi

# Casper's live root comes from immutable squashfs layers which contain the
# Ubuntu ISO's stock module tree. Copy the custom release and new Qualcomm
# firmware into Casper's writable overlay so modules and WCN7850 firmware
# remain usable after the initramfs itself is discarded.
#
# The hook must run from scripts/casper-bottom, NOT scripts/local-bottom. In a
# casper boot it is casper's own mountroot() that runs, and it reaches
# /scripts/local only through mount_top()/mount_premount(). local_bottom() is
# called from local_mount_root() alone, and casper replaces that function, so a
# local-bottom hook is silently never executed: the live root keeps the stock
# module tree and any unit it was meant to install does not exist (the image
# boots normally and reports nothing).
#
# Every phase is driven by run_scripts(), which SOURCES that phase's ORDER file
# instead of globbing the directory, and initramfs-tools expects ORDER to exist.
# A script dropped into the phase directory is dead weight until its entry is
# appended to ORDER as well.
CASPER_BOTTOM_ORDER="$WORK/initrd-root/scripts/casper-bottom/ORDER"
[[ -f "$CASPER_BOTTOM_ORDER" ]] || { printf 'no casper-bottom/ORDER in the stock initrd: %s\n' "$CASPER_BOTTOM_ORDER" >&2; exit 1; }
mkdir -p "$WORK/initrd-root/scripts/casper-bottom"
cat > "$WORK/initrd-root/scripts/casper-bottom/65a16-live-root" <<EOF
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\${1:-}" in prereqs) prereqs; exit 0 ;; esac

mkdir -p /root/usr/lib/modules /root/usr/lib/firmware
rm -rf /root/usr/lib/modules/*
cp -a /usr/lib/modules/$VERSION /root/usr/lib/modules/
cp -a /usr/lib/firmware/qcom /root/usr/lib/firmware/
cp -a /usr/lib/firmware/ath12k /root/usr/lib/firmware/
EOF
chmod 0755 "$WORK/initrd-root/scripts/casper-bottom/65a16-live-root"

if [[ "$A16_HARVEST" == 1 ]]; then
  cat >> "$WORK/initrd-root/scripts/casper-bottom/65a16-live-root" <<EOF

# Harvest hook: install the collector and a oneshot unit into the live root so
# the session reports its own device state without a keyboard.
#
# Triggered by a timer with OnBootSec, NOT by WantedBy=multi-user.target: a
# unit ordered After=multi-user.target does not start until the whole
# multi-user transaction is finished, and on this medium that transaction can
# sit for minutes (snapd.seeded, cloud-final, casper-md5check still hashing the
# ISO) or never complete at all -- observed in QEMU: multi-user.target still
# "start waiting" long after the login prompt, a16-harvest.service stuck in
# "start waiting" behind it, nothing harvested. The timer fires at a fixed
# wall-clock point after boot instead, independent of which units are still
# running, so the panel always gets its summary.
mkdir -p /root/usr/local/sbin /root/etc/systemd/system /root/etc/systemd/system/timers.target.wants
cp -a /usr/local/sbin/a16-harvest /root/usr/local/sbin/a16-harvest
chmod 0755 /root/usr/local/sbin/a16-harvest
cat > /root/etc/systemd/system/a16-harvest.service <<'UNIT'
[Unit]
Description=A16 bring-up harvest
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/a16-harvest
StandardOutput=journal+console
StandardError=journal+console
UNIT
cat > /root/etc/systemd/system/a16-harvest.timer <<'TIMER'
[Unit]
Description=A16 bring-up harvest timer
[Timer]
OnBootSec=${A16_HARVEST_DELAY}
AccuracySec=1s
Unit=a16-harvest.service
[Install]
WantedBy=timers.target
TIMER
ln -sf ../a16-harvest.timer /root/etc/systemd/system/timers.target.wants/a16-harvest.timer
EOF
fi

# Register the hook with casper-bottom: run_scripts sources the phase's ORDER
# file, so without this entry the script written above is never executed.
printf '%s\n' '/scripts/casper-bottom/65a16-live-root "$@"' \
              '[ -e /conf/param.conf ] && . /conf/param.conf' \
  >> "$CASPER_BOTTOM_ORDER"

mapfile -t INITRD_KERNEL_RELEASES < <(find "$WORK/initrd-root/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ ${#INITRD_KERNEL_RELEASES[@]} -eq 1 && "${INITRD_KERNEL_RELEASES[0]}" == "$VERSION" ]] || {
  printf 'Expected only initramfs kernel release %s; found: %s\n' "$VERSION" "${INITRD_KERNEL_RELEASES[*]:-none}" >&2
  exit 1
}
(cd "$WORK/initrd-root" && find . -print0 | sort -z \
  | cpio --null -o -H newc --owner=0:0 --quiet | gzip -9 > "$WORK/a16-initrd")

# The stock daily stores platform workarounds in $cmdline and places quiet and
# splash after "---". Generate explicit entries instead of trying to mutate
# one line in-place. All four A16 entries are always written; DEFAULT_MENU_ENTRY
# picks which one boots unattended.
# Diagnostic console. A bare "earlycon" resolves to nothing on the A16 (the
# firmware exposes no SPCR/DBG2 and the DTB has no /chosen stdout-path), and
# with CONFIG_FB_EFI unset the only text console is fbcon, which cannot appear
# until the DRM side probes. A boot that dies before that is therefore
# indistinguishable from a dead machine: black screen, no output at all. The
# kernel is built with CONFIG_EFI_EARLYCON=y, so setting
# DIAGNOSTIC_CONSOLE=earlycon=efifb prints kernel messages straight onto the
# EFI/GOP framebuffer from the first kernel instruction onward.
DIAGNOSTIC_CONSOLE="${DIAGNOSTIC_CONSOLE:-earlycon}"
# Menu index that boots by default: 0 DTB diagnostic, 1 DTB graphics,
# 2 ACPI diagnostic, 3 ACPI graphics. ACPI is the confirmed-working path on the
# A16, so diagnostic builds default to entry 2.
DEFAULT_MENU_ENTRY="${DEFAULT_MENU_ENTRY:-0}"
DIAGNOSTIC_OPTIONS="console=tty0 $DIAGNOSTIC_CONSOLE keep_bootcon loglevel=8 ignore_loglevel initcall_debug systemd.show_status=1 rd.systemd.show_status=1 plymouth.enable=0 systemd.unit=multi-user.target panic=0 module_blacklist=msm modprobe.blacklist=msm"
cat > "$WORK/a16-grub.cfg" <<EOF
set timeout=30
set default=$DEFAULT_MENU_ENTRY

loadfont unicode
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

set platform_cmdline=
smbios --type 4 --get-string 5 --set proc_version
regexp "Snapdragon.*" "\$proc_version"
if [ \$? = 0 ]; then
  if [ \$lockdown != "y" ]; then
    cutmem 0x8800000000 0x8fffffffff
  fi
  platform_cmdline="clk_ignore_unused pd_ignore_unused arm64.nopauth"
fi

menuentry "$MENU_BUILD - DTB diagnostic console" {
  set gfxpayload=keep
  linux /casper/vmlinuz \$platform_cmdline acpi=off $DIAGNOSTIC_OPTIONS ---
  devicetree $DTB_ISO_PATH
  initrd /casper/initrd
}

menuentry "$MENU_BUILD - DTB graphics" {
  set gfxpayload=keep
  linux /casper/vmlinuz \$platform_cmdline acpi=off console=tty0 quiet splash ---
  devicetree $DTB_ISO_PATH
  initrd /casper/initrd
}

menuentry "$MENU_BUILD - ACPI diagnostic console" {
  set gfxpayload=keep
  linux /casper/vmlinuz \$platform_cmdline acpi=force $DIAGNOSTIC_OPTIONS ---
  initrd /casper/initrd
}

menuentry "$MENU_BUILD - ACPI graphics" {
  set gfxpayload=keep
  linux /casper/vmlinuz \$platform_cmdline acpi=force console=tty0 quiet splash ---
  initrd /casper/initrd
}

menuentry "Boot from next volume" {
  exit 1
}

menuentry "UEFI Firmware Settings" {
  fwsetup
}
EOF

if [[ "$STOCK_ENTRIES" == 1 ]]; then
cat >> "$WORK/a16-grub.cfg" <<EOF

menuentry "$MENU_BUILD - stock Ubuntu kernel graphics (control)" {
  set gfxpayload=keep
  linux /casper/vmlinuz.stock \$platform_cmdline acpi=force console=tty0 quiet splash ---
  initrd /casper/initrd.stock
}

menuentry "$MENU_BUILD - stock Ubuntu kernel diagnostic console (control)" {
  set gfxpayload=keep
  linux /casper/vmlinuz.stock \$platform_cmdline acpi=force $DIAGNOSTIC_OPTIONS ---
  initrd /casper/initrd.stock
}
EOF
fi

# Loader-provided device tree. The Linux DTS for this machine deliberately has
# no /memory node: Qualcomm platforms boot DT by installing the firmware's own
# device tree (which carries /memory and the reserved regions) into the UEFI
# configuration table, with the Linux DTB applied on top. GRUB's `devicetree`
# command replaces that tree outright, which is why the DTB entries above cannot
# boot. This entry therefore passes acpi=off but NO devicetree, so the kernel
# uses whatever the firmware/loader installed (dtbloader, or the firmware's own
# FDT table when present). It only makes sense on a machine that has one
# installed, so it ships with the harvest builds used to test that path.
if [[ "$A16_HARVEST" == 1 ]]; then
cat >> "$WORK/a16-grub.cfg" <<EOF

menuentry "$MENU_BUILD - firmware/loader-provided DT diagnostic console" {
  set gfxpayload=keep
  linux /casper/vmlinuz \$platform_cmdline acpi=off $DIAGNOSTIC_OPTIONS ---
  initrd /casper/initrd
}
EOF
fi

grep -vE '(\.\/)?(casper/vmlinuz|casper/initrd|boot/grub/grub.cfg|casper/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb)$' \
  "$WORK/iso-files/md5sum.txt" > "$WORK/a16-md5sum.txt"
{
  printf '%s  ./casper/vmlinuz\n' "$(md5sum "$STAGE/Image" | awk '{print $1}')"
  printf '%s  ./casper/initrd\n' "$(md5sum "$WORK/a16-initrd" | awk '{print $1}')"
  printf '%s  ./boot/grub/grub.cfg\n' "$(md5sum "$WORK/a16-grub.cfg" | awk '{print $1}')"
  printf '%s  .%s\n' "$(md5sum "$DTB_SOURCE" | awk '{print $1}')" "$DTB_ISO_PATH"
  if [[ "$STOCK_ENTRIES" == 1 ]]; then
    printf '%s  ./casper/vmlinuz.stock\n' "$(md5sum "$WORK/iso-files/vmlinuz" | awk '{print $1}')"
    printf '%s  ./casper/initrd.stock\n' "$(md5sum "$WORK/iso-files/initrd" | awk '{print $1}')"
  fi
} >> "$WORK/a16-md5sum.txt"

FINAL="$OUT/ubuntu-desktop-a16-$VERSION-$BUILD_VARIANT.iso"
rm -f "$FINAL"
echo "Writing custom Ubuntu A16 live/install ISO"
xorriso -indev "$BASE_ISO" -outdev "$FINAL" -boot_image any replay \
  -map "$STAGE/Image" /casper/vmlinuz \
  -map "$WORK/a16-initrd" /casper/initrd \
  -map "$DTB_SOURCE" "$DTB_ISO_PATH" \
  -map "$WORK/a16-grub.cfg" /boot/grub/grub.cfg \
  "${STOCK_MAPS[@]}" \
  -map "$WORK/a16-md5sum.txt" /md5sum.txt -commit >/dev/null

mkdir -p "$WORK/verify"
xorriso -osirrox on -indev "$FINAL" \
  -extract /casper/vmlinuz "$WORK/verify/vmlinuz" \
  -extract /casper/initrd "$WORK/verify/initrd" \
  -extract "$DTB_ISO_PATH" "$WORK/verify/a16.dtb" \
  -extract /boot/grub/grub.cfg "$WORK/verify/grub.cfg" >/dev/null
cmp "$STAGE/Image" "$WORK/verify/vmlinuz"
cmp "$DTB_SOURCE" "$WORK/verify/a16.dtb"
EXPECTED_KERNEL_LINES=4
if [[ "$STOCK_ENTRIES" == 1 ]]; then
  EXPECTED_KERNEL_LINES=6
  xorriso -osirrox on -indev "$FINAL" \
    -extract /casper/vmlinuz.stock "$WORK/verify/vmlinuz.stock" \
    -extract /casper/initrd.stock "$WORK/verify/initrd.stock" >/dev/null
  cmp "$WORK/iso-files/vmlinuz" "$WORK/verify/vmlinuz.stock"
  cmp "$WORK/iso-files/initrd" "$WORK/verify/initrd.stock"
  grep -qF "stock Ubuntu kernel graphics (control)" "$WORK/verify/grub.cfg"
  grep -qF "stock Ubuntu kernel diagnostic console (control)" "$WORK/verify/grub.cfg"
fi
if [[ "$A16_HARVEST" == 1 ]]; then
  EXPECTED_KERNEL_LINES=$((EXPECTED_KERNEL_LINES + 1))
  grep -qF "$MENU_BUILD - firmware/loader-provided DT diagnostic console" "$WORK/verify/grub.cfg"
fi
[[ "$(grep -cE '^[[:space:]]*linux[[:space:]]+/casper/vmlinuz' "$WORK/verify/grub.cfg")" -eq "$EXPECTED_KERNEL_LINES" ]]
[[ "$(grep -cF "devicetree $DTB_ISO_PATH" "$WORK/verify/grub.cfg")" -eq 2 ]]
grep -qF 'platform_cmdline="clk_ignore_unused pd_ignore_unused arm64.nopauth"' "$WORK/verify/grub.cfg"
grep -qF "$MENU_BUILD - DTB diagnostic console" "$WORK/verify/grub.cfg"
grep -qF "$MENU_BUILD - DTB graphics" "$WORK/verify/grub.cfg"
grep -qF "$MENU_BUILD - ACPI diagnostic console" "$WORK/verify/grub.cfg"
grep -qF "$MENU_BUILD - ACPI graphics" "$WORK/verify/grub.cfg"
grep -qF "module_blacklist=msm" "$WORK/verify/grub.cfg"
lsinitramfs "$WORK/verify/initrd" > "$WORK/initramfs-listing.txt"
grep -q "usr/lib/modules/$VERSION" "$WORK/initramfs-listing.txt"
grep -q "usr/lib/firmware/qcom" "$WORK/initramfs-listing.txt"
grep -q "usr/lib/firmware/ath12k/WCN7850" "$WORK/initramfs-listing.txt"
grep -q "scripts/casper-bottom/65a16-live-root" "$WORK/initramfs-listing.txt"
grep -qF '/scripts/casper-bottom/65a16-live-root "$@"' "$CASPER_BOTTOM_ORDER"
if [[ "$A16_HARVEST" == 1 ]]; then
  grep -q "usr/local/sbin/a16-harvest" "$WORK/initramfs-listing.txt"
  grep -q "OnBootSec=$A16_HARVEST_DELAY" "$WORK/initrd-root/scripts/casper-bottom/65a16-live-root"
fi
(cd "$(dirname "$FINAL")" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256")
(cd "$(dirname "$FINAL")" && sha256sum --check "$(basename "$FINAL").sha256")
FINAL_BYTES="$(stat -c%s "$FINAL")"
if [[ -n "$SPLIT_SIZE" ]]; then
  split -b "$SPLIT_SIZE" -d -a 2 --additional-suffix=.part "$FINAL" "$FINAL."
  rm "$FINAL"
  FINAL_DESCRIPTION="$(basename "$FINAL").00.part, .01.part, ..."
else
  FINAL_DESCRIPTION="$(basename "$FINAL")"
fi

cat <<EOF

========== A16 Ubuntu live ISO build summary ==========
Host OS: ${PRETTY_NAME:-${ID:-unknown}}
Host kernel: $(uname -srmo)
Kernel release: $VERSION
Kernel address size: ${VA_BITS}-bit VA/PA test
Ubuntu daily base: $BASE_URL
Qualcomm firmware RPM: $QCOM_FIRMWARE_RPM
Atheros firmware RPM: $ATHEROS_FIRMWARE_RPM
Custom Image: $(stat -c%s "$STAGE/Image") bytes
Custom initramfs: $(stat -c%s "$WORK/a16-initrd") bytes
A16 DTB: $(stat -c%s "$DTB_SOURCE") bytes
Custom module tree: $(du -sb "$STAGE/modules/lib/modules/$VERSION" | awk '{print $1}') bytes
Final artifact: $FINAL_DESCRIPTION
Final ISO size before splitting: $FINAL_BYTES bytes
Checksum: $(basename "$FINAL").sha256
Live boot payload: custom A16 kernel, DTB, modules, and Qualcomm firmware
Default boot path: menu entry $DEFAULT_MENU_ENTRY, diagnostic console ($DIAGNOSTIC_CONSOLE)
Alternate boot paths: DTB graphics, ACPI diagnostic, and ACPI graphics
Stock-kernel control entries: $STOCK_ENTRIES (1 = /casper/vmlinuz.stock + /casper/initrd.stock on media)
Harvest hook: $A16_HARVEST (1 = a16-harvest collector + oneshot unit in the live root, plus a loader-provided-DT entry)
Live-root handoff: custom modules and firmware copied into Casper overlay
Note: the live session uses the custom kernel; the Ubuntu installer may still
install Ubuntu's packaged kernel until custom-kernel installation is added.
=======================================================
EOF
