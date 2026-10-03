#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
OUT="${OUT:-$ROOT/build/out}"
DEST="${DEST:-$ROOT/out}"
VERSION="$(make -s -C "$TREE" O="$OUT" ARCH=arm64 kernelrelease)"
STAGE="$DEST/zenbook-a16-$VERSION"
DTB_REL="qcom/glymur-asus-zenbook-a16-ux3607oa.dtb"
rm -rf "$STAGE"; mkdir -p "$STAGE/dtbs" "$STAGE/modules" "$STAGE/metadata"
cp "$OUT/arch/arm64/boot/Image" "$STAGE/Image"
cp -a "$OUT/arch/arm64/boot/dts/." "$STAGE/dtbs/"
make -C "$TREE" O="$OUT" ARCH=arm64 INSTALL_MOD_PATH="$STAGE/modules" \
  INSTALL_MOD_STRIP=1 modules_install
[[ -f "$STAGE/dtbs/$DTB_REL" ]] || { echo "Missing A16 DTB: $DTB_REL" >&2; exit 1; }
cp "$OUT/.config" "$STAGE/metadata/kernel.config"

# Every profile produces the required-option audit. Fedora-config builds also
# produce Fedora source metadata; defconfig-based profiles record that Fedora's
# config was intentionally not used.
if [[ -f "$OUT/config-audit.txt" ]]; then
  cp "$OUT/config-audit.txt" "$STAGE/metadata/config-audit.txt"
else
  printf '%s\n' "not generated" > "$STAGE/metadata/config-audit.txt"
fi
if [[ -f "$OUT/fedora-config-source.txt" ]]; then
  cp "$OUT/fedora-config-source.txt" "$STAGE/metadata/fedora-config-source.txt"
else
  printf '%s\n' "not used (known-good arm64 defconfig profile)" > "$STAGE/metadata/fedora-config-source.txt"
fi

printf '%s\n' "$VERSION" > "$STAGE/metadata/kernel-version.txt"
git -C "$TREE" rev-parse HEAD > "$STAGE/metadata/build-commit.txt"
if [[ -f "$ROOT/build/linux-next-base-commit.txt" ]]; then
  cp "$ROOT/build/linux-next-base-commit.txt" "$STAGE/metadata/linux-next-commit.txt"
else
  git -C "$TREE" rev-parse HEAD > "$STAGE/metadata/linux-next-commit.txt"
fi
{
  echo "$DTB_REL"
  sha256sum "$STAGE/dtbs/$DTB_REL"
} > "$STAGE/metadata/a16-dtb.txt"
find "$STAGE/modules/lib/modules/$VERSION" -type f -name '*.ko*' -printf '%P\n' \
  | grep -Ei '(^|/)(qcom|msm|glymur)|qcom|msm|glymur' \
  | sort > "$STAGE/metadata/qcom-modules.txt" || true
find "$STAGE/modules/lib/modules/$VERSION" -type f -name '*.ko*' -printf '%P\n' \
  | sort > "$STAGE/metadata/all-modules.txt"
tar --zstd -C "$DEST" -cf "$DEST/zenbook-a16-$VERSION.tar.zst" "$(basename "$STAGE")"
sha256sum "$DEST/zenbook-a16-$VERSION.tar.zst" > "$DEST/zenbook-a16-$VERSION.tar.zst.sha256"
