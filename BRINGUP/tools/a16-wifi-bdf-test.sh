#!/usr/bin/env bash
# a16-wifi-bdf-test.sh -- serve the A16's own Windows board data to ath12k.
#
#   sudo bash /home/jc/a16-payload/a16-wifi-bdf-test.sh              # try the candidates in order
#   sudo bash /home/jc/a16-payload/a16-wifi-bdf-test.sh --dry-run    # build + list only, install nothing
#   sudo A16_CANDIDATES="bdwlan.e18 bdwlan.elf" bash ... /a16-wifi-bdf-test.sh
#
# Why: the QCC2072 (17cb:1112) on this machine loads its firmware fine and then dies at
#   failed to fetch board data for bus=pci,...,subsystem-device=e14f,qmi-chip-id=33,
#   qmi-board-id=255,variant=UX3407Q from ath12k/QCC2072/hw1.0/board-2.bin
# The installed board-2.bin carries keys for other boards only (e12/e19/e24, subsystem
# e15a/1110).  The machine's own Windows WLAN package (qcwlancol8480 -- the package bound
# to PCI VEN_17CB&DEV_1112&SUBSYS_E14F105B) ships 25 board images; this script wraps each
# one under the exact key the driver asks for, rebuilds board-2.bin with QCA's own
# ath12k-bdencoder, reloads ath12k and records whether the card came up.
#
# It never overwrites the installed board-2.bin without a backup, and if no candidate
# works it puts the original back.  Per-board RF calibration lives in these images: the
# one that makes the radio come up is the one this machine's Windows driver uses, but a
# candidate that merely "loads" is not proof of correct calibration -- say which one won.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="${A16_FW_DIR:-/lib/firmware/ath12k/QCC2072/hw1.0}"
PKG="${A16_BOARD_SRC:-$REPO/firmware/windows-driverstore-2026-09-16/wlan/qcwlancol8480.inf_arm64_d440e12aca6ddc77}"
BDENCODER="${A16_BDENCODER:-$REPO/scripts/ath12k-bdencoder}"
PAYLOAD="${A16_PAYLOAD:-$HOME/a16-payload}"
LOG="${A16_LOG:-$PAYLOAD/A16WIFI-$(date +%Y%m%d-%H%M%S).log}"
DRY_RUN=0; VERIFY=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --verify)  VERIFY=1 ;;
  "")        ;;
  *)         echo "usage: $0 [--dry-run|--verify]" >&2; exit 2 ;;
esac

KEY_NAME="bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255"
KEY_FULL="$KEY_NAME,variant=UX3407Q"
# most likely first: the package's own generic image and the one named for this part,
# then the per-board-id variants grouped by their inner BDF identity
DEFAULT_CANDIDATES="bdwlan_qcc2072_1p0_ncm820A.elf bdwlan.elf bdwlan.e18 bdwlan.e15 bdwlan.e17 bdwlan.e16 \
bdwlan.e0f bdwlan.e10 bdwlan.e11 bdwlan.e12 bdwlan.e13 bdwlan.e14 bdwlan.e01 bdwlan.e02 bdwlan.e06 \
bdwlan.e07 bdwlan.e08 bdwlan.e09 bdwlan.e03 bdwlan.e0a bdwlan.e0b bdwlan.e0c bdwlan.e0d bdwlan.e0e \
bdwlan.e05 bdwlan_qcc2072_1p0_ncm820A_AC_Shrimp.elf"
CANDIDATES="${A16_CANDIDATES:-$DEFAULT_CANDIDATES}"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }

: > "$LOG" 2>/dev/null || { LOG=/var/tmp/a16-wifi-bdf-test.log; : > "$LOG"; }
say "[a16-wifi] === a16-wifi-bdf-test $(date +%Y%m%d-%H%M%S) $( [ $DRY_RUN = 1 ] && echo '(dry run)') ==="
say "[a16-wifi] firmware dir : $FW_DIR"
say "[a16-wifi] board source : $PKG"
say "[a16-wifi] bdencoder    : $BDENCODER"

if [ "$(id -u)" != 0 ] && [ "${A16_NONROOT:-0}" != 1 ]; then
  say "[a16-wifi] FATAL: run with sudo (it installs into $FW_DIR and reloads ath12k)"
  exit 1
fi
[ -x "$BDENCODER" ] || { say "[a16-wifi] FATAL: no bdencoder at $BDENCODER"; exit 1; }
[ -d "$PKG" ] || { say "[a16-wifi] FATAL: board source $PKG missing (git pull in ~/A16Build)"; exit 1; }
[ -d "$FW_DIR" ] || { say "[a16-wifi] FATAL: $FW_DIR missing"; exit 1; }

board_file=""
for f in "$FW_DIR/board-2.bin" "$FW_DIR/board-2.bin.zst"; do
  [ -f "$f" ] && board_file="$f" && break
done
[ -n "$board_file" ] || { say "[a16-wifi] FATAL: no board-2.bin[.zst] in $FW_DIR"; exit 1; }
say "[a16-wifi] installed    : $board_file ($(stat -c %s "$board_file") bytes)"

WORK="$(mktemp -d /tmp/a16-wifi-XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

sec "stage the installed board-2.bin (so nothing of it is lost)"
cp -a "$board_file" "$WORK/original.board-2.bin"
if [ "$board_file" = "$FW_DIR/board-2.bin.zst" ]; then
  zstdcat "$board_file" > "$WORK/board-2.bin" || { say "[a16-wifi] FATAL: zstdcat failed"; exit 1; }
else
  cp -a "$board_file" "$WORK/board-2.bin"
fi
sha256sum "$WORK/original.board-2.bin" | tee -a "$LOG"
( cd "$WORK" && python3 "$BDENCODER" -e board-2.bin ) 2>&1 | tee -a "$LOG"
[ -s "$WORK/board-2.json" ] || { say "[a16-wifi] FATAL: bdencoder did not produce board-2.json"; exit 1; }
say "[a16-wifi] extracted entries:"; python3 - "$WORK/board-2.json" <<'PY' | tee -a "$LOG"
import json, sys
for b in json.load(open(sys.argv[1]))[0]["board"]:
    print("    data=%-30s names=%s" % (b["data"][:30], len(b["names"])))
PY

unload_ath12k() {
  # this kernel ships the set as separate modules and the PCI glue holds the core, so
  # `modprobe -r ath12k` fails on its own -- unload the dependents by name, in order
  modprobe -r ath12k_wifi7_pci ath12k_wifi7 ath12k 2>/dev/null
  sleep 1
  local left
  left="$(lsmod | awk '$1 ~ /^ath12k/ {printf "%s(used-by %s) ", $1, $3}')"
  if [ -n "$left" ]; then
    say "  NOTE: still loaded: $left"
    say "  The candidate board file IS installed; a live reload cannot proceed while those hold"
    say "  the device.  Reboot (GRUB entry 2) and run:  sudo bash $0 --verify"
    return 1
  fi
  say "  ath12k set unloaded"
  return 0
}

# ------------------------------------------------------------------ per-candidate run
try_candidate() {
  local cand="$1" idx="$2" total="$3"
  sec "[$idx/$total] $cand"
  [ -f "$PKG/$cand" ] || { say "  SKIP: $PKG/$cand not found"; return 2; }
  local img="$WORK/cand.board.bin"
  cp -f "$PKG/$cand" "$img"
  say "  image: $cand  $(stat -c %s "$img") bytes  sha256 $(sha256sum "$img" | cut -c1-16)"

  # rebuild board-2.bin = the installed entries + our key pointing at this candidate
  python3 - "$WORK" "$cand" "$KEY_NAME" "$KEY_FULL" <<'PY' | tee -a "$LOG"
import json, sys
work, cand, key_name, key_full = sys.argv[1:5]
js = json.load(open(work + "/board-2.json"))
js[0]["board"] = [b for b in js[0]["board"] if not any("e14f" in n for n in b["names"])]
js[0]["board"].append({"names": [key_full, key_name], "data": "cand.board.bin"})
json.dump(js, open(work + "/board-2.json", "w"), indent=4)
print("  json: our key added (variant + plain) -> cand.board.bin")
PY
  ( cd "$WORK" && python3 "$BDENCODER" -c board-2.json >/dev/null ) || { say "  BUILD FAILED"; return 2; }
  local built="$WORK/board-2.bin"
  say "  built: $(stat -c %s "$built") bytes sha256 $(sha256sum "$built" | cut -c1-16)"
  # verify the end state, not the build's own chatter: re-extract what was just built
  local vdir="$WORK/verify"; rm -rf "$vdir"; mkdir -p "$vdir"; cp -f "$built" "$vdir/board-2.bin"
  ( cd "$vdir" && python3 "$BDENCODER" -e board-2.bin >/dev/null 2>&1 )
  if grep -q 'subsystem-device=e14f' "$vdir/board-2.json" 2>/dev/null; then
    say "  verify: rebuilt file carries our key; entries=$(python3 -c "import json;print(len(json.load(open('$vdir/board-2.json'))[0]['board']))" 2>/dev/null) $(python3 -c "import json;print(sorted(k for b in json.load(open('$vdir/board-2.json'))[0]['board'] for k in b['names'] if 'e14f' in k))" 2>/dev/null)"
  else
    say "  verify: OUR KEY IS MISSING from the rebuilt file -- not installing this candidate"
    return 2
  fi

  if [ $DRY_RUN = 1 ]; then
    say "  DRY RUN: not installing, not reloading"
    [ "$idx" = 1 ] && cp -f "$built" "$PAYLOAD/A16-board-2-dryrun-example.bin"
    return 2
  fi

  install -m 0644 "$built" "$FW_DIR/board-2.bin" || { say "  INSTALL FAILED"; return 2; }
  cp -a "$built" "$PAYLOAD/A16-board-2-$(basename "$cand").bin" 2>/dev/null || true  # identity, even if the run aborts
  if [ -f "$FW_DIR/board-2.bin.zst" ]; then
    [ -f "$FW_DIR/board-2.bin.zst.a16bak" ] || mv -f "$FW_DIR/board-2.bin.zst" "$FW_DIR/board-2.bin.zst.a16bak"
  fi
  sync
  modprobe -r ath12k_wifi7_pci ath12k_wifi7 ath12k 2>/dev/null; sleep 1
  if ! unload_ath12k; then return 3; fi
  modprobe ath12k
  local waited=0 net="" fail=""
  while [ $waited -lt 20 ]; do
    sleep 2; waited=$((waited+2))
    fail="$(journalctl -k --since "-${waited}s" --no-pager 2>/dev/null | grep -E 'failed to fetch board data|qmi failed to load board|firmware crashed|failed to load board data' | tail -2)"
    net="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)"
    [ -n "$net" ] && break
    [ -n "$fail" ] && break
  done
  local lines; lines="$(journalctl -k --since "-40s" --no-pager 2>/dev/null | grep -E 'ath12k' | tail -6)"
  say "  --- ath12k log ---"
  printf '%s\n' "$lines" | sed 's/^/    /' | tee -a "$LOG"
  if [ -n "$net" ]; then
    say "  RESULT: interface up: $net"
    ip -br addr show "$net" 2>&1 | sed 's/^/    /' | tee -a "$LOG"
    return 0
  fi
  if [ -n "$fail" ]; then
    say "  RESULT: still failing at the board file:"
    printf '%s\n' "$fail" | sed 's/^/    /' | tee -a "$LOG"
  else
    say "  RESULT: no wl interface and no board error in 20 s -- inconclusive, read the log above"
  fi
  return 1
}

if [ $VERIFY = 1 ]; then
  sec "verify the boot in front of me"
  wlif="$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)"
  fails="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c 'failed to fetch board data')"
  say "[verify] wl interface : ${wlif:-<none>}"
  say "[verify] 'failed to fetch board data' lines in this boot: $fails"
  inst="$FW_DIR/board-2.bin"; [ -f "$inst" ] || inst="$FW_DIR/board-2.bin.zst"
  isum="$(sha256sum "$inst" 2>/dev/null | cut -d' ' -f1)"
  say "[verify] installed    : $inst"
  say "[verify] sha256       : $isum"
  match="<not one of this script's builds>"
  for c in "$PAYLOAD"/A16-board-2-*.bin; do
    [ -f "$c" ] || continue
    [ "$(sha256sum "$c" | cut -d' ' -f1)" = "$isum" ] && match="$(basename "$c" .bin)"
  done
  say "[verify] candidate    : $match"
  { iw dev 2>/dev/null | sed -n '1,10p'; rfkill list 2>/dev/null | head -4; \
    nmcli -t dev status 2>/dev/null; } | sed 's/^/    /' | tee -a "$LOG"
  aps="$(timeout 40 nmcli -t -f SSID dev wifi list 2>/dev/null | grep -c .)"
  say "[verify] visible APs  : $aps"
  if [ -n "$wlif" ] && [ "$fails" = 0 ]; then
    say "[verify] PASS: the radio came up with this board file -- the board-data gap is closed"
  else
    say "[verify] HOLD: no wl interface or the board fetch still failed -- run the candidate loop"
  fi
  say "[verify] log: $LOG"
  exit 0
fi

sec "candidates ($(printf '%s' "$CANDIDATES" | wc -w) images)"
idx=0; total=$(printf '%s' "$CANDIDATES" | wc -w); winner=""; inconclusive=""; blocked=0
for cand in $CANDIDATES; do
  idx=$((idx+1))
  try_candidate "$cand" "$idx" "$total"
  rc=$?
  if [ $rc = 0 ]; then winner="$cand"; break; fi
  if [ $rc = 3 ]; then blocked=1; break; fi
  if [ $rc = 1 ]; then inconclusive="$inconclusive $cand"; fi
done

sec "summary"
if [ $DRY_RUN = 1 ]; then
  say "[a16-wifi] DRY RUN: nothing was installed into $FW_DIR and ath12k was not reloaded."
elif [ -n "$winner" ]; then
  say "[a16-wifi] WORKED: $winner is installed as $FW_DIR/board-2.bin"
  say "[a16-wifi] kept a copy: $PAYLOAD/A16-board-2-$winner"
  cp -a "$FW_DIR/board-2.bin" "$PAYLOAD/A16-board-2-$winner" 2>/dev/null || true
  say "[a16-wifi] next: iw dev / nmcli dev wifi list  -- and compare dmesg board id, RSSI and TX power"
elif [ $blocked = 1 ]; then
  say "[a16-wifi] stopped before the reload: the ath12k set is still bound to 0004:01:00.0."
  say "[a16-wifi] the candidate is installed as $FW_DIR/board-2.bin -- exercise it with a reboot:"
  say "[a16-wifi]   sudo bash $0 --verify"
else
  say "[a16-wifi] no candidate produced a wl interface."
  [ -n "$inconclusive" ] && say "[a16-wifi] inconclusive (no error, no interface):$inconclusive"
  if [ $DRY_RUN != 1 ]; then
    install -m 0644 "$WORK/board-2.bin" "$FW_DIR/board-2.bin"
    say "[a16-wifi] restored the original board-2.bin contents to $FW_DIR/board-2.bin"
    modprobe -r ath12k 2>/dev/null; sleep 1; modprobe ath12k
  fi
  say "[a16-wifi] the remaining gaps would be the driver/DT, not the board file -- bring this log back"
fi
say "[a16-wifi] log: $LOG"
exit 0
