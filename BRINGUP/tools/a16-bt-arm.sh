#!/usr/bin/env bash
# a16-bt-arm.sh -- get the Bluetooth serdev test DTB in front of the next boot WITHOUT
#                  needing anybody to hit the right row of the GRUB menu.
#
#   sudo bash a16-bt-arm.sh            # arm  : put the patched DTB where the DT entries read it
#   bash a16-bt-arm.sh status          # read-only: which file is which, what is live now
#   sudo bash a16-bt-arm.sh revert     # disarm: put the stock DTB back
#   sudo bash a16-bt-arm.sh --dry-run  # say what arm would do, write nothing
#
# Why: menu entry [8] loads /boot/glymur-a16-bt-test.dtb, and the last two reboots still came
# up on the stock DTB -- the entries' own cmdline is identical to [8]'s, so the boot that
# happened was the config's default entry, [1], not [8].  Entries [1]-[4] all load the *stock*
# glymur DTB from one of two paths; arming replaces those two files in place (with a backup),
# so whichever of [1]-[4] the machine takes, it gets the Bluetooth client.  revert undoes it.
#
# What arming does to the DTB (see scripts/a16-bt-dtb.sh, which builds it):
#   * adds a `bluetooth { compatible = "qcom,wcn7850-bt"; ... }` child to uart14's serial node
#     -> hci_uart.ko carries `alias: of:N*T*Cqcom,wcn7850-bt`, so the serdev bus binds it and
#        hci_qca (CONFIG_BT_HCIUART_QCA=y, inside hci_uart) runs the firmware download
#   * adds six always-on `regulator-fixed` stubs (vddio/vddaon/vdddig/vddrfa0p8/vddrfa1p2/
#     vddrfa1p9) -- the driver's devm_regulator_bulk_get() requires them and the A16's DTS
#     describes none of the module's rails.  STUBS: they satisfy the driver, they do not
#     control hardware.  That is why this is a test, not a fix.
#
# If the machine does not come up on the armed DTB: pick entry [0] ("installed Ubuntu 7.2
# staged on the ESP (ACPI)") -- it boots from the ESP with no devicetree line at all, so it is
# unaffected by anything here -- then run `sudo bash a16-bt-arm.sh revert`.  From Windows, drop
# <path>.a16stock back over <path> on the ESP (a16boot ..........\.a16stock -> the .dtb name).

set -u

MODE="${1:-arm}"
DRY=0
case "$MODE" in
  --dry-run|-n) MODE=arm; DRY=1 ;;
esac

# sha256 of the two DTBs, so "armed" and "restored" are provable rather than asserted
PATCHED_SHA="e9692e4d25b3451fdbd9d6a067f7a6a5b83196ab6a45467325a8ea6a606371c0"   # fallback only
STOCK_SHA="ddb423f8dda683a965c1ffe6c4933d15bd9714dae7e740faf8d306b968056ac2"

# the paths the menu entries actually read:
#   [1]      -> /a16boot/glymur-asus-zenbook-a16-ux3607oa.dtb   (this is the ESP file)
#   [2],[3],[4] -> /boot/glymur-asus-zenbook-a16-ux3607oa.dtb   (rootfs)
DEFAULT_FILES="/boot/glymur-asus-zenbook-a16-ux3607oa.dtb:/boot/efi/a16boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
FILES="${A16_DT_FILES:-$DEFAULT_FILES}"
# a colon-separated A16_DT_FILES is a test hook: it lets the whole arm/revert cycle be run
# against copies in /tmp without root and without touching the real boot files.
TESTMODE=0
[ -n "${A16_DT_FILES:-}" ] && TESTMODE=1

PATCHED_CANDIDATES="/boot/glymur-a16-bt-test.dtb /boot/efi/a16boot/glymur-a16-bt-test.dtb"

# under sudo $HOME is /root: keep the log where the invoking user can read it
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
LOG="${A16_LOG:-$HOME/a16-payload/A16BTARM-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || LOG="/var/tmp/a16-bt-arm-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG="/var/tmp/a16-bt-arm-$(date +%Y%m%d-%H%M%S).log"

# The patched artifact gets rebuilt as the patch grows (a16-bt-dtb.sh writes a sidecar next to
# it), so take the expected sha from that sidecar when one exists: a hardcoded sha that lags the
# artifact would make this script refuse to arm the very file we just built.
SIDECAR=""
for s in /boot/glymur-a16-bt-test.dtb.sha256 /boot/efi/a16boot/glymur-a16-bt-test.dtb.sha256 \
         "$HOME/a16-payload/glymur-a16-bt-test.dtb.sha256"; do
  [ -f "$s" ] || continue
  v="$(awk 'NR==1 && $1 ~ /^[0-9a-f]{64}$/ {print $1}' "$s")"
  [ -n "$v" ] && { PATCHED_SHA="$v"; SIDECAR="$s"; break; }
done

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
patched_src() {
  local c
  for c in $PATCHED_CANDIDATES "$HOME/a16-payload/glymur-a16-bt-test.dtb"; do
    [ -f "$c" ] || continue
    [ "$(sha "$c")" = "$PATCHED_SHA" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

live_dtbtest() {   # prints: 1 if the running DT carries the serdev client, else 0
  local hits=0
  [ -d /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/bluetooth ] && hits=1
  if command -v dtc >/dev/null 2>&1; then
    local n
    n="$(dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -c 'qcom,wcn7850-bt' || true)"
    [ "${n:-0}" -gt 0 ] && hits=1
  fi
  printf '%s' "$hits"
}

report_live() {
  sec "the DTB running right now"
  local model rails
  model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  rails="$(ls -d /proc/device-tree/regulator-bt-* 2>/dev/null | wc -l)"
  say "[a16-bt] model        : ${model:-unknown}"
  say "[a16-bt] stub rails   : $rails of 6"
  if [ "$(live_dtbtest)" = 1 ]; then
    say "[a16-bt] serdev client: PRESENT (compatible qcom,wcn7850-bt is in the live tree)"
    if [ -d /sys/class/bluetooth ] && [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
      say "[a16-bt] controllers  : $(ls /sys/class/bluetooth | paste -sd' ' -)"
    else
      say "[a16-bt] controllers  : none yet -- if the kernel log shows the qca firmware lines,"
      say "[a16-bt]                read what it asked for; if it shows nothing, hci_uart did not"
      say "[a16-bt]                bind (journalctl -k -b 0 | grep -iE 'qca|bluetooth|hci|serdev')"
    fi
  else
    say "[a16-bt] serdev client: ABSENT -- stock DTB, so no Bluetooth this boot, tty or not."
    say "[a16-bt] driver side  : complete on this kernel (hci_uart alias of:N*T*Cqcom,wcn7850-bt,"
    say "[a16-bt]                CONFIG_BT_HCIUART_QCA=y, btqca.ko installed); only the DT node"
    say "[a16-bt]                is missing.  Two ways to get it: this script's arm mode, or"
    say "[a16-bt]                reboot and pick the [8] row of the GRUB menu."
  fi
}

per_file() {   # prints one line per file: what it is, and whether a backup exists
  local f k s bk
  for f in $(printf '%s' "$FILES" | tr ':' ' '); do
    if [ -f "$f" ]; then
      s="$(sha "$f")"
      case "$s" in
        "$PATCHED_SHA") k="PATCHED (BT test)" ;;
        "$STOCK_SHA")   k="stock" ;;
        *)              k="other (${s:0:16}...)" ;;
      esac
      bk="no"; [ -f "$f.a16stock" ] && bk="yes ($(sha "$f.a16stock" | cut -c1-16)...)"
      printf '   %-56s %s   backup=%s\n' "$f" "$k" "$bk"
    else
      printf '   %-56s MISSING\n' "$f"
    fi
  done
}

do_status() {
  report_live
  sec "the files the DT entries load"
  per_file
  sec "the patched artifact, if present"
  local s
  s="$(patched_src || true)"
  if [ -n "${s:-}" ]; then say "[a16-bt] source for arming: $s  ($(stat -c %s "$s") bytes)"; else
    say "[a16-bt] no file matches the expected patched sha ${PATCHED_SHA:0:16}... --"
    say "[a16-bt] rebuild with: bash $HOME/a16-payload/a16-bt-dtb.sh --dry-run"
  fi
  say "[a16-bt] log: $LOG"
}

do_arm() {
  if [ "$(id -u)" != 0 ] && [ "$TESTMODE" = 0 ] && [ "$DRY" = 0 ]; then
    say "[a16-bt-arm] FATAL: needs root (sudo bash $0) -- /boot and the ESP are root-owned"
    exit 1
  fi
  sec "pick the patched DTB and prove it is the one we think"
  local SRC; SRC="$(patched_src || true)"
  if [ -z "${SRC:-}" ]; then
    say "[a16-bt-arm] no candidate matches ${PATCHED_SHA:0:16}... -- trying a rebuild"
    if [ -x "$HOME/a16-payload/a16-bt-dtb.sh" ]; then
      bash "$HOME/a16-payload/a16-bt-dtb.sh" --dry-run >/dev/null 2>&1 || true
      SRC="$(patched_src || true)"
    fi
  fi
  [ -n "${SRC:-}" ] || { say "[a16-bt-arm] FATAL: cannot find or rebuild the patched DTB"; exit 1; }
  say "[a16-bt-arm] source: $SRC"
  say "[a16-bt-arm] size  : $(stat -c %s "$SRC") bytes   sha256 ${PATCHED_SHA:0:16}... (expected)"
  say "[a16-bt-arm] expect: from ${SIDECAR:-the built-in default (no sidecar found)}"
  if ! dtc -I dtb -O dts "$SRC" 2>/dev/null | grep -q 'qcom,wcn7850-bt'; then
    say "[a16-bt-arm] FATAL: that file does not decompile to a DTB with the serdev client in it"
    exit 1
  fi
  say "[a16-bt-arm] parsed: dtc decompiles it and finds compatible = qcom,wcn7850-bt"

  sec "arm each path the entries load (backup once, never overwrite a backup)"
  local f before after bk n=0
  for f in $(printf '%s' "$FILES" | tr ':' ' '); do
    if [ ! -f "$f" ]; then say "[a16-bt-arm] skip (not present): $f"; continue; fi
    before="$(sha "$f")"; bk="$f.a16stock"
    if [ "$before" = "$PATCHED_SHA" ]; then
      say "[a16-bt-arm] already armed: $f"
    fi
    if [ ! -f "$bk" ]; then
      if [ "$before" = "$STOCK_SHA" ]; then
        say "[a16-bt-arm] backup  : $bk  (stock)"
      else
        say "[a16-bt-arm] backup  : $bk  (WARNING: it was not the known stock sha ${STOCK_SHA:0:16}...)"
      fi
      [ "$DRY" = 1 ] || cp -a "$f" "$bk"
    else
      say "[a16-bt-arm] backup  : $bk already exists -- left alone"
    fi
    if [ "$DRY" = 1 ]; then
      say "[a16-bt-arm] DRY RUN : would install $SRC over $f (${before:0:16}... -> ${PATCHED_SHA:0:16}...)"
      continue
    fi
    cp -f "$SRC" "$f" || { say "[a16-bt-arm] FATAL: copy failed for $f"; exit 1; }
    chmod 0644 "$f" 2>/dev/null || true
    [ "$(id -u)" = 0 ] && chown root:root "$f" 2>/dev/null || true
    after="$(sha "$f")"
    if [ "$after" = "$PATCHED_SHA" ]; then
      say "[a16-bt-arm] ARMED   : $f  ${before:0:16}... -> ${after:0:16}..."
      n=$((n+1))
    else
      say "[a16-bt-arm] FATAL   : $f reads back as ${after:0:16}..., expected ${PATCHED_SHA:0:16}..."
      exit 1
    fi
  done
  say "[a16-bt-arm] $n file(s) armed."
  if [ "$DRY" = 1 ]; then say "[a16-bt-arm] DRY RUN -- nothing was written."; say "[a16-bt-arm] log: $LOG"; return 0; fi

  sec "now reboot"
  say "[a16-bt-arm] Any of the DT rows ([1] [2] [3] [4]) now loads the Bluetooth test DTB, so the"
  say "[a16-bt-arm] next boot gets it whether or not the menu is touched.  After it comes up:"
  say ""
  say "    bash $HOME/a16-payload/a16-bt-setup.sh status"
  say ""
  say "[a16-bt-arm] Expect, in that output:"
  say "    serdev client: PRESENT, stub rails: 6 of 6"
  say "    then either a controller under /sys/class/bluetooth (hci0 -- Bluetooth is up), or the"
  say "    qca firmware lines in the kernel log naming the file it wanted.  Both are real datums;"
  say "    'MISSING /dev/ttyHS1' is expected and harmless -- serdev means there is no tty."
  say ""
  say "[a16-bt-arm] To go back to the stock DTB:  sudo bash $0 revert"
  say "[a16-bt-arm] If the machine will not come up at all: pick the [0] row (ACPI, no devicetree"
  say "[a16-bt-arm] line, so it is immune to this), then run the revert above.  From Windows, the"
  say "[a16-bt-arm] ESP's a16boot\\glymur-asus-zenbook-a16-ux3607oa.dtb.a16stock copied back over"
  say "[a16-bt-arm] glymur-asus-zenbook-a16-ux3607oa.dtb also restores it."
  say "[a16-bt-arm] log: $LOG"
}

do_revert() {
  if [ "$(id -u)" != 0 ] && [ "$TESTMODE" = 0 ]; then
    say "[a16-bt-arm] FATAL: needs root (sudo bash $0 revert)"; exit 1
  fi
  sec "restore the stock DTB wherever a backup exists"
  local f bk after n=0
  for f in $(printf '%s' "$FILES" | tr ':' ' '); do
    bk="$f.a16stock"
    if [ ! -f "$bk" ]; then say "[a16-bt-arm] no backup for $f -- nothing to restore"; continue; fi
    if [ "$DRY" = 1 ]; then say "[a16-bt-arm] DRY RUN : would restore $bk over $f"; continue; fi
    cp -f "$bk" "$f" || { say "[a16-bt-arm] FATAL: restore failed for $f"; exit 1; }
    chmod 0644 "$f" 2>/dev/null || true
    [ "$(id -u)" = 0 ] && chown root:root "$f" 2>/dev/null || true
    after="$(sha "$f")"
    if [ "$after" = "$STOCK_SHA" ]; then
      say "[a16-bt-arm] RESTORED: $f  ${after:0:16}... (stock)"
      n=$((n+1))
    else
      say "[a16-bt-arm] WARNING : $f reads back as ${after:0:16}..., not the stock sha ${STOCK_SHA:0:16}..."
    fi
  done
  say "[a16-bt-arm] $n file(s) restored.  The backup .a16stock files are kept, so arming again"
  say "[a16-bt-arm] costs nothing.  Reboot to boot the stock DTB."
  say "[a16-bt-arm] log: $LOG"
}

say "[a16-bt-arm] === a16-bt-arm $MODE $(date +%Y%m%d-%H%M%S) ===  (root=$([ "$(id -u)" = 0 ] && echo yes || echo no))"
case "$MODE" in
  arm)    do_arm ;;
  status) do_status ;;
  revert) do_revert ;;
  *)      printf 'usage: %s [arm|status|revert|--dry-run]\n' "$0"; exit 2 ;;
esac
exit 0
