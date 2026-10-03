#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
OUT="${OUT:-$ROOT/build/out}"
JOBS="${JOBS:-$(nproc)}"
source "$ROOT/config/build.env"
FEDORA_CONFIG_URL="${FEDORA_CONFIG_URL_OVERRIDE:-$FEDORA_CONFIG_URL}"
REQUIRED_CONFIG="$ROOT/config/a16-required.config"
BUILD_OVERRIDES="$ROOT/config/build-overrides.config"
KERNEL_CONFIG_PROFILE="${KERNEL_CONFIG_PROFILE:-fedora}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
BUILD_CC="${BUILD_CC:-${CROSS_COMPILE}gcc}"
BUILD_HOSTCC="${BUILD_HOSTCC:-gcc}"
MAKE_ARGS=(O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$BUILD_CC" HOSTCC="$BUILD_HOSTCC")

apply_config_fragment() {
  local fragment="$1" requirement symbol value
  while IFS= read -r requirement; do
    if [[ "$requirement" =~ ^CONFIG_[A-Za-z0-9_]+= ]]; then
      symbol="${requirement%%=*}"
      value="${requirement#*=}"
    elif [[ "$requirement" =~ ^\#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
      symbol="${BASH_REMATCH[1]}"
      value=n
    else
      continue
    fi
    symbol="${symbol#CONFIG_}"
    case "$value" in
      y) "$TREE/scripts/config" --file "$OUT/.config" --enable "$symbol" ;;
      m) "$TREE/scripts/config" --file "$OUT/.config" --module "$symbol" ;;
      n) "$TREE/scripts/config" --file "$OUT/.config" --disable "$symbol" ;;
      *) echo "Unsupported config value: $requirement" >&2; exit 2 ;;
    esac
  done < "$fragment"
}

mkdir -p "$OUT"
[[ -x "$TREE/scripts/config" ]] || { echo "Missing kernel scripts/config" >&2; exit 2; }

echo "Kernel config profile: $KERNEL_CONFIG_PROFILE"
case "$KERNEL_CONFIG_PROFILE" in
  known-good|defconfig)
    # Stay as close as possible to the last known-good ARM64 defconfig, but make
    # the complete Fedora USB-root path built-in. Fedora's stock initramfs was
    # generated for its own kernel and cannot reliably provide modules for our
    # custom uname; the observed failure was dm_mod missing followed by an
    # indefinite wait for the root UUID.
    make -C "$TREE" "${MAKE_ARGS[@]}" defconfig
    for symbol in \
      USB USB_XHCI_HCD USB_XHCI_PLATFORM USB_DWC3 USB_DWC3_QCOM \
      PHY_QCOM_QMP_USB SCSI BLK_DEV_SD USB_STORAGE USB_UAS \
      BTRFS_FS BLK_DEV_DM; do
      "$TREE/scripts/config" --file "$OUT/.config" --enable "$symbol"
    done
    apply_config_fragment "$REQUIRED_CONFIG"
    make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
    "$ROOT/scripts/audit-config.sh" "$OUT/.config" "$REQUIRED_CONFIG" | tee "$OUT/config-audit.txt"
    {
      echo "profile=$KERNEL_CONFIG_PROFILE"
      echo "source=arm64-defconfig+a16-required"
      echo "root_builtins=USB USB_XHCI_HCD USB_XHCI_PLATFORM USB_DWC3 USB_DWC3_QCOM PHY_QCOM_QMP_USB SCSI BLK_DEV_SD USB_STORAGE USB_UAS BTRFS_FS BLK_DEV_DM"
    } > "$OUT/config-source.txt"
    ;;
  fedora)
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
    echo "Downloading Fedora Rawhide AArch64 kernel config"
    curl --fail --location --retry 3 "$FEDORA_CONFIG_URL" -o "$OUT/.config"
    {
      echo "profile=fedora"
      echo "source=$FEDORA_CONFIG_URL"
      printf 'sha256='
      sha256sum "$OUT/.config" | awk '{print $1}'
    } > "$OUT/config-source.txt"

    # Normalize Fedora's config against linux-next first, then force the small
    # built-in set needed before a matching custom initramfs can load modules.
    make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
    for fragment in "$BUILD_OVERRIDES" "$REQUIRED_CONFIG"; do
      apply_config_fragment "$fragment"
    done
    make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
    "$ROOT/scripts/audit-config.sh" "$OUT/.config" "$BUILD_OVERRIDES" | tee "$OUT/config-audit.txt"
    "$ROOT/scripts/audit-config.sh" "$OUT/.config" "$REQUIRED_CONFIG" | tee -a "$OUT/config-audit.txt"
    ;;
  ubuntu|distro)
    # Fresh-start profile: start from the configuration of the distribution
    # kernel that is known to boot this machine — Ubuntu's arm64 -generic config,
    # taken verbatim from /usr/src/linux-headers-<ver>-generic/.config of the
    # linux-headers deb matching the live ISO's kernel release — instead of
    # arm64 defconfig plus this repo's assumption fragments. Nothing is forced on
    # top beyond turning off module signing (Secure Boot is disabled on the test
    # device and signing only adds a build dependency). olddefconfig lets the
    # tree resolve symbols linux-next added or removed.
    UBUNTU_CONFIG="${UBUNTU_CONFIG:-$ROOT/config/ubuntu-generic-arm64.config}"
    [[ -f "$UBUNTU_CONFIG" ]] || { echo "Missing Ubuntu kernel config: $UBUNTU_CONFIG" >&2; exit 2; }
    cp "$UBUNTU_CONFIG" "$OUT/.config"
    # Ubuntu's config points at files only its own packaging ships
    # (debian/canonical-certs.pem) and signs every module; neither exists or
    # matters here, and the first makes the build fail outright.
    "$TREE/scripts/config" --file "$OUT/.config" \
      --disable MODULE_SIG \
      --disable MODULE_SIG_ALL \
      --disable DEBUG_INFO \
      --disable DEBUG_INFO_DWARF5 \
      --disable DEBUG_INFO_BTF \
      --disable DEBUG_INFO_BTF_MODULES \
      --set-str SYSTEM_TRUSTED_KEYS "" \
      --set-str SYSTEM_REVOCATION_KEYS "" \
      --set-str SYSTEM_BLACKLIST_HASH_LIST ""
    make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
    if grep -qE '^CONFIG_[A-Z_]*(KEYS|KEY|HASH_LIST)[A-Z_]*=".*debian/' "$OUT/.config"; then
      grep -nE '^CONFIG_[A-Z_]*(KEYS|KEY|HASH_LIST)[A-Z_]*=".*debian/' "$OUT/.config" >&2
      echo "Config still references a distribution-only file path" >&2
      exit 2
    fi
    {
      echo "profile=$KERNEL_CONFIG_PROFILE"
      echo "source=$UBUNTU_CONFIG"
      printf 'sha256='
      sha256sum "$UBUNTU_CONFIG" | awk '{print $1}'
    } > "$OUT/config-source.txt"
    printf '%s\n' "not used (ubuntu distro config profile)" > "$OUT/fedora-config-source.txt"
    # The a16-required audit is informational here: it encodes the old
    # live-media design's built-in demands, and this profile deliberately keeps
    # the distribution's module layout instead.
    "$ROOT/scripts/audit-config.sh" "$OUT/.config" "$REQUIRED_CONFIG" | tee "$OUT/config-audit.txt" || true
    ;;
  *)
    echo "Unknown KERNEL_CONFIG_PROFILE: $KERNEL_CONFIG_PROFILE (use known-good, defconfig, fedora, or ubuntu)" >&2
    exit 2
    ;;
esac

make -C "$TREE" "${MAKE_ARGS[@]}" -j"$JOBS" Image dtbs modules
