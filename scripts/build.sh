#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
OUT="${OUT:-$ROOT/build/out}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$OUT"
make -C "$TREE" O="$OUT" ARCH=arm64 defconfig
make -C "$TREE" O="$OUT" -j"$JOBS" ARCH=arm64 \
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" Image dtbs modules
