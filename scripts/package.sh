#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
OUT="${OUT:-$ROOT/build/out}"
DEST="${DEST:-$ROOT/out}"
VERSION="$(make -s -C "$TREE" O="$OUT" ARCH=arm64 kernelrelease)"
STAGE="$DEST/zenbook-a16-$VERSION"
rm -rf "$STAGE"; mkdir -p "$STAGE/dtbs" "$STAGE/modules"
cp "$OUT/arch/arm64/boot/Image" "$STAGE/Image"
cp -a "$OUT/arch/arm64/boot/dts/." "$STAGE/dtbs/"
make -C "$TREE" O="$OUT" ARCH=arm64 INSTALL_MOD_PATH="$STAGE/modules" modules_install
git -C "$TREE" rev-parse HEAD > "$STAGE/linux-next-commit.txt"
tar --zstd -C "$DEST" -cf "$DEST/zenbook-a16-$VERSION.tar.zst" "$(basename "$STAGE")"
sha256sum "$DEST/zenbook-a16-$VERSION.tar.zst" > "$DEST/zenbook-a16-$VERSION.tar.zst.sha256"
