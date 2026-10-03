#!/usr/bin/env bash
# make-a16-qcc2072-board-2.sh -- rebuild the A16's QCC2072 board-2.bin from its own
#                               Windows board image, and optionally install it.
#
#   bash scripts/make-a16-qcc2072-board-2.sh                 # build into firmware/…/rebuilt/
#   sudo bash scripts/make-a16-qcc2072-board-2.sh --install  # build, install, reload ath12k
#   A16_WIFI_IMAGE=bdwlan.e18 bash scripts/make-a16-qcc2072-board-2.sh   # try another vendor image
#
# Inputs, all in-repo: the pristine distro container
# (firmware/ath12k-board-2-qcc2072-e14f/board-2.bin.zst.distro-20260911) and the vendor
# board image from the machine's own Windows WLAN package
# (firmware/windows-driverstore-2026-09-16/wlan/qcwlancol8480.inf_arm64_d440e12aca6ddc77/).
# The default image is the one that works on this machine; the expected sha256 is checked
# when that default is used, so a silent change in the inputs cannot pass unnoticed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BDENCODER="${A16_BDENCODER:-$REPO/scripts/ath12k-bdencoder}"
DISTRO_ZST="$REPO/firmware/ath12k-board-2-qcc2072-e14f/board-2.bin.zst.distro-20260911"
PKG="${A16_BOARD_SRC:-$REPO/firmware/windows-driverstore-2026-09-16/wlan/qcwlancol8480.inf_arm64_d440e12aca6ddc77}"
IMAGE="${A16_WIFI_IMAGE:-bdwlan_qcc2072_1p0_ncm820A.elf}"
OUTDIR="${A16_OUT:-$REPO/firmware/ath12k-board-2-qcc2072-e14f/rebuilt}"
EXPECT="314e2d5702bd5431bd7abc6f71c6610f79f79ece50c5f854ccadeaee1bb27b49"
KEY_A="bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255"
KEY_B="$KEY_A,variant=UX3407Q"
FW_DIR="${A16_FW_DIR:-/lib/firmware/ath12k/QCC2072/hw1.0}"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

say() { printf '%s\n' "$*"; }
die() { printf 'make-a16-qcc2072-board-2: %s\n' "$*" >&2; exit 1; }

[ -f "$DISTRO_ZST" ] || die "missing $DISTRO_ZST"
[ -f "$PKG/$IMAGE" ] || die "missing vendor image $PKG/$IMAGE (git pull)"
[ -x "$BDENCODER" ] || die "missing $BDENCODER"

WORK="$(mktemp -d /tmp/a16-board2-XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"

zstdcat "$DISTRO_ZST" > "$WORK/board-2.bin" || die "zstdcat failed on $DISTRO_ZST"
say "pristine container : $DISTRO_ZST ($(stat -c %s "$DISTRO_ZST") bytes) -> $(stat -c %s "$WORK/board-2.bin") bytes"
( cd "$WORK" && python3 "$BDENCODER" -e board-2.bin ) > "$WORK/extract.txt" 2>&1 || die "bdencoder -e failed: $(tail -2 "$WORK/extract.txt")"
grep -c . "$WORK/extract.txt" >/dev/null && say "extracted          : $(grep -c 'created size' "$WORK/extract.txt") entries"

cp -f "$PKG/$IMAGE" "$WORK/cand.bin"
python3 - "$WORK" "$KEY_A" "$KEY_B" <<'PY' || die "adding the key failed"
import json, sys
work, key_a, key_b = sys.argv[1:4]
js = json.load(open(work + "/board-2.json"))
js[0]["board"] = [b for b in js[0]["board"] if not any("e14f" in n for n in b["names"])]
js[0]["board"].append({"names": [key_b, key_a], "data": "cand.bin"})
json.dump(js, open(work + "/board-2.json", "w"), indent=4)
print("board entries now  :", len(js[0]["board"]), "(ours added as #%d)" % len(js[0]["board"]))
PY
( cd "$WORK" && python3 "$BDENCODER" -c board-2.json ) > "$WORK/build.txt" 2>&1 || die "bdencoder -c failed: $(tail -2 "$WORK/build.txt")"

# verify the end state by re-extracting what was built, not by trusting the build output
mkdir -p "$WORK/verify"; cp -f "$WORK/board-2.bin" "$WORK/verify/board-2.bin"
( cd "$WORK/verify" && python3 "$BDENCODER" -e board-2.bin ) >/dev/null 2>&1
grep -q 'subsystem-device=e14f' "$WORK/verify/board-2.json" \
  || die "rebuilt file does not carry our key (verification failed)"
say "verified           : our key present; entries=$(python3 -c "import json;print(len(json.load(open('$WORK/verify/board-2.json'))[0]['board']))")"

cp -f "$WORK/board-2.bin" "$OUTDIR/board-2.bin"
sha="$(sha256sum "$OUTDIR/board-2.bin" | cut -d' ' -f1)"
say "built              : $OUTDIR/board-2.bin  $(stat -c %s "$OUTDIR/board-2.bin") bytes"
say "sha256             : $sha"
if [ "$IMAGE" = "bdwlan_qcc2072_1p0_ncm820A.elf" ]; then
  [ "$sha" = "$EXPECT" ] && say "matches the verified build" || die "sha256 differs from the verified build ($EXPECT) -- inputs changed, re-test before installing"
fi

if [ "$INSTALL" = 1 ]; then
  [ "$(id -u)" = 0 ] || die "--install needs root"
  [ -d "$FW_DIR" ] || die "$FW_DIR missing"
  [ -f "$FW_DIR/board-2.bin.zst" ] && [ ! -f "$FW_DIR/board-2.bin.zst.a16bak" ] \
    && mv -f "$FW_DIR/board-2.bin.zst" "$FW_DIR/board-2.bin.zst.a16bak" && say "kept distro file as board-2.bin.zst.a16bak"
  install -m 0644 "$OUTDIR/board-2.bin" "$FW_DIR/board-2.bin" || die "install failed"
  say "installed          : $FW_DIR/board-2.bin"
  modprobe -r ath12k_wifi7_pci ath12k_wifi7 ath12k 2>/dev/null; sleep 1
  modprobe ath12k; sleep 3
  say "ath12k             : $(lsmod | awk '$1 ~ /^ath12k/ {printf "%s(%s) ", $1, $3}')"
  say "after reload       : $(ls /sys/class/net | grep -E '^wl' || echo 'no wl interface (reboot, then re-check)')"
  say "board-fetch fails  : $(journalctl -k --since '-40s' --no-pager 2>/dev/null | grep -c 'failed to fetch board data') in the last 40 s"
fi
