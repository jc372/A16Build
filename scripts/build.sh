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
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
BUILD_CC="${BUILD_CC:-${CROSS_COMPILE}gcc}"
BUILD_HOSTCC="${BUILD_HOSTCC:-gcc}"
MAKE_ARGS=(O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$BUILD_CC" HOSTCC="$BUILD_HOSTCC")

mkdir -p "$OUT"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
[[ -x "$TREE/scripts/config" ]] || { echo "Missing kernel scripts/config" >&2; exit 2; }

echo "Downloading Fedora Rawhide AArch64 kernel config"
curl --fail --location --retry 3 "$FEDORA_CONFIG_URL" -o "$OUT/.config"
{
  echo "source=$FEDORA_CONFIG_URL"
  printf 'sha256='
  sha256sum "$OUT/.config" | awk '{print $1}'
} > "$OUT/fedora-config-source.txt"

# Normalize Fedora's config against linux-next first, then force the small
# built-in set needed before a matching custom initramfs can load modules.
make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
for fragment in "$BUILD_OVERRIDES" "$REQUIRED_CONFIG"; do
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
done
make -C "$TREE" "${MAKE_ARGS[@]}" olddefconfig
"$ROOT/scripts/audit-config.sh" "$OUT/.config" "$BUILD_OVERRIDES" | tee "$OUT/config-audit.txt"
"$ROOT/scripts/audit-config.sh" "$OUT/.config" "$REQUIRED_CONFIG" | tee -a "$OUT/config-audit.txt"

make -C "$TREE" "${MAKE_ARGS[@]}" -j"$JOBS" Image dtbs modules
