#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
OUT="${OUT:-$ROOT/build/out}"
JOBS="${JOBS:-$(nproc)}"
source "$ROOT/config/build.env"
FEDORA_CONFIG_URL="${FEDORA_CONFIG_URL_OVERRIDE:-$FEDORA_CONFIG_URL}"
REQUIRED_CONFIG="$ROOT/config/a16-required.config"

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
make -C "$TREE" O="$OUT" ARCH=arm64 olddefconfig
while IFS= read -r requirement; do
  [[ "$requirement" =~ ^CONFIG_[A-Za-z0-9_]+= ]] || continue
  symbol="${requirement%%=*}"
  value="${requirement#*=}"
  symbol="${symbol#CONFIG_}"
  case "$value" in
    y) "$TREE/scripts/config" --file "$OUT/.config" --enable "$symbol" ;;
    m) "$TREE/scripts/config" --file "$OUT/.config" --module "$symbol" ;;
    n) "$TREE/scripts/config" --file "$OUT/.config" --disable "$symbol" ;;
    *) echo "Unsupported required config value: $requirement" >&2; exit 2 ;;
  esac
done < "$REQUIRED_CONFIG"
make -C "$TREE" O="$OUT" ARCH=arm64 olddefconfig
"$ROOT/scripts/audit-config.sh" "$OUT/.config" | tee "$OUT/config-audit.txt"

make -C "$TREE" O="$OUT" -j"$JOBS" ARCH=arm64 \
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" Image dtbs modules
