#!/usr/bin/env bash
# a16-bt-setup.sh -- bring up the A16's Bluetooth from its own Windows firmware.
#
#   bash a16-bt-setup.sh status           # read-only: what exists, what is loaded, what the kernel asked for
#   sudo bash a16-bt-setup.sh install     # put the BT blobs where btqca looks for them
#   sudo bash a16-bt-setup.sh attach      # btattach the QCA protocol on the BT UART and report
#   sudo bash a16-bt-setup.sh all         # install + attach
#
# Why this shape: the A16's BT hangs off uart14 (`a98000.serial`, tty `ttyHS1`, DT alias
# serial1) which is *already* enabled and driven by qcom_geni_serial -- the kernel creates the
# tty, it just has no Bluetooth child node, so nothing binds.  bluez is installed, so the
# legacy H4 path works: `btattach -P qca` runs hci_uart + btqca over that tty, and btqca then
# asks for its patchram/NVM by name.  The Windows package ships exactly those files:
#
#     hmtbtfw20.tlv  -> qca/hmtbtfw20.tlv     (btqca: "qca/hmtbtfw%02x.tlv" for QCA_WCN7850)
#     hmtnv20.bXXX   -> qca/hmtnv20.bXXX      (btqca: "qca/%s%02x%s.bin", stem "hmtnv", board suffix)
#
# If a DTB node (`&uart14 { bluetooth { compatible = "qcom,wcn7850-bt"; ... } }`, six supplies:
# vddio/vddaon/vdddig/vddrfa0p8/vddrfa1p2/vddrfa1p9) is added later, the serdev path takes over
# and this script stops being needed -- but attaching first is the cheap way to learn whether
# the chip answers at all.
set -u

REPO="${A16_REPO:-/home/jc/A16Build}"
BT_SRC="${A16_BT_SRC:-$REPO/firmware/windows-driverstore-2026-09-16/bluetooth/qcbluetooth8480.inf_arm64_f8c8ac4a2910b3ce}"
MANIFEST="$REPO/firmware/windows-driverstore-2026-09-16/MANIFEST.tsv"
QCA_DIR="${A16_QCA_DIR:-/lib/firmware/qca}"
TTY="${A16_BT_TTY:-/dev/ttyHS1}"
SPEED="${A16_BT_SPEED:-3000000}"
LOG="${A16_LOG:-$HOME/a16-payload/A16BT-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
# under sudo, $HOME is /root: keep the log where the invoking user can read it
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
[ -d "$HOME/a16-payload" ] || mkdir -p "$HOME/a16-payload" 2>/dev/null || LOG=/var/tmp/a16-bt.log
LOG="${A16_LOG:-$HOME/a16-payload/A16BT-$(date +%Y%m%d-%H%M%S).log}"
: > "$LOG" 2>/dev/null || { LOG=/var/tmp/a16-bt-$(date +%Y%m%d-%H%M%S).log; : > "$LOG"; }

# the BT UART's tty: named after the DT alias/UART, so find it from sysfs rather than guessing
tty_for() {   # tty_for <platform-device-substring>  -> prints the tty name, or nothing
  local dev="$1" t n d
  for t in /sys/class/tty/*/; do
    n="$(basename "$t")"
    d="$(readlink -f "$t/device" 2>/dev/null)"
    case "$d" in *"$dev"*) printf '%s' "$n"; return 0;; esac
  done
  return 1
}
find_bt_tty() { local n; n="$(tty_for a98000)" && printf '/dev/%s' "$n"; }
if [ -z "${A16_BT_TTY:-}" ]; then
  TTY="$(find_bt_tty || printf '%s' /dev/ttyHS1)"
fi

MODE="${1:-status}"
say "[a16-bt] === a16-bt-setup $MODE $(date +%Y%m%d-%H%M%S) ==="

cmd_rebind() {
  [ "$(id -u)" = 0 ] || { say "[a16-bt] FATAL: rebind needs sudo"; exit 1; }
  sec "re-register the BT UART (a98000.serial)"
  local drv=/sys/bus/platform/drivers/qcom_geni_serial dev=a98000.serial
  [ -d "$drv" ] || { say "[a16-bt] no $drv"; return 1; }
  say "[a16-bt] before: tty=$(tty_for a98000 || echo none)"
  if [ -e "$drv/$dev" ]; then
    echo "$dev" > "$drv/unbind" && say "[a16-bt] unbound $dev"
    sleep 1
  fi
  if echo "$dev" > "$drv/bind" 2>/dev/null; then
    say "[a16-bt] bound $dev"
  else
    say "[a16-bt] bind FAILED (the port may be held by another driver: check 'lsmod | grep msm')"
  fi
  sleep 3
  say "[a16-bt] after : tty=$(tty_for a98000 || echo none)"
  say "[a16-bt] kernel:"; journalctl -k --since "-20s" --no-pager 2>/dev/null | grep -iE 'a98000|ttyHS|geni|serial' | tail -10 | sed 's/^/    /' | tee -a "$LOG"
}

cmd_status() {
  sec "which DTB is live"
  # Decide from the *live tree*, not from a node-name glob: decompile it and look for the
  # serdev client's compatible string, which cannot exist for any other reason.  This is the
  # check that answers "did entry [8] actually run?" -- the entries' cmdlines are identical,
  # so the DTB is the only evidence.
  local hits=0 rails
  [ -d /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/bluetooth ] && hits=1
  if command -v dtc >/dev/null 2>&1; then
    local n
    n="$(dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -c 'qcom,wcn7850-bt' || true)"
    [ "${n:-0}" -gt 0 ] && hits=1
  fi
  rails="$(ls -d /proc/device-tree/regulator-bt-* 2>/dev/null | wc -l)"
  say "[a16-bt] model     : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  say "[a16-bt] stub rails: $rails of 6"
  if [ "$hits" = 1 ]; then
    say "[a16-bt] DTB       : PATCHED -- the serdev client is live (compatible = qcom,wcn7850-bt)"
    PATCHED=1
  else
    say "[a16-bt] DTB       : STOCK / unpatched -- uart14 has no serdev client, so nothing"
    say "[a16-bt]             can bind hci_uart/hci_qca and btattach can never open a tty."
    say "[a16-bt] driver side: complete on this kernel -- hci_uart.ko carries the alias"
    say "[a16-bt]             of:N*T*Cqcom,wcn7850-bt, CONFIG_BT_HCIUART_QCA=y, btqca.ko is"
    say "[a16-bt]             installed.  Only the DT node is missing.  Two ways to get it:"
    say "[a16-bt]             sudo bash ~/a16-payload/a16-bt-arm.sh   (no menu interaction),"
    say "[a16-bt]             or reboot and select the [8] row of the GRUB menu."
    PATCHED=0
  fi
  if [ "$PATCHED" = 1 ]; then
    sec "the BT stack"
    say "[a16-bt] /sys/class/bluetooth: $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ' || echo '(none)')"
    say "[a16-bt] modules   : $(lsmod | awk '$1 ~ /^(hci_uart|bluetooth|btqca|rfcomm)$/ {printf "%s(%s) ", $1, $3}')"
    say "[a16-bt] kernel log:"
    journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE 'qca|bluetooth|hci_uart|serdev|firmware|wcn' | grep -viE 'xhci|ath12k' | tail -15 | sed 's/^/    /'
  fi
  sec "carrier side"
  say "[a16-bt] BT UART      : $TTY  ($( [ -c "$TTY" ] && echo 'char device present' || echo MISSING))"
  say "[a16-bt] UART ttys    : a98000(BT)=$(tty_for a98000 || echo none)  894000(debug)=$(tty_for 894000 || echo none)"
  say "[a16-bt] platform dev : $(ls -d /sys/bus/platform/devices/*a98000* 2>/dev/null || echo none)  driver=$(basename "$(readlink -f /sys/bus/platform/devices/a98000.serial/driver 2>/dev/null)" 2>/dev/null)"
  say "[a16-bt] stack        : modules: $(lsmod | awk '$1 ~ /^(bluetooth|hci_uart|btqca|btbcm)$/ {printf "%s ", $1}' || true)"
  say "[a16-bt] /sys/class/bluetooth: $(ls /sys/class/bluetooth 2>/dev/null | paste -sd' ' - || echo '(absent - no controller)')"
  say "[a16-bt] rfkill       : $(rfkill list 2>/dev/null | grep -c Bluetooth) bluetooth entries"
  sec "firmware in $QCA_DIR (what btqca asks for)"
  say "[a16-bt] rampatch: qca/hmtbtfw%02x.tlv  -> needs hmtbtfw20.tlv for rom_ver 0x20"
  say "[a16-bt] nvm     : qca/hmtnv%02x.b<board-id>  (the id comes from the chip, so the exact"
  say "[a16-bt]           file can only be known once it talks; the Windows package ships 4:"
  say "[a16-bt]           b105 b10f b112 b3b -- if the chip wants another one, ASUS ships none)"
  for f in hmtbtfw20.tlv hmtbtfw20.ver hmtnv20.b105 hmtnv20.b10f hmtnv20.b112 hmtnv20.b3b clnbtfw10.tlv clnbtnv10.b03 clnbtnv10.b17 bsrc_bt.bin; do
    if [ -f "$QCA_DIR/$f" ]; then say "   installed: $f  ($(stat -c %s "$QCA_DIR/$f") bytes)"; else say "   MISSING  : $f  -- run 'sudo bash $0 install'"; fi
  done
  sec "what the kernel said last time it tried"
  journalctl -k --since "-30min" --no-pager 2>/dev/null | grep -iE 'bluetooth|btqca|hci_uart|hci[0-9]|rampatch|patchram|qca/|nv[0-9][0-9]\.bin' | tail -15 | sed 's/^/    /' | tee -a "$LOG"
  say ""
  say "[a16-bt] log: $LOG"
}

cmd_install() {
  [ "$(id -u)" = 0 ] || { say "[a16-bt] FATAL: install needs sudo"; exit 1; }
  [ -d "$BT_SRC" ] || { say "[a16-bt] FATAL: $BT_SRC missing (git pull in $REPO)"; exit 1; }
  sec "verify the source files against the repo manifest"
  local bad=0
  for f in "$BT_SRC"/*.tlv "$BT_SRC"/*.bin "$BT_SRC"/hmtnv20.b* "$BT_SRC"/clnbtnv10.b*; do
    [ -f "$f" ] || continue
    local want got
    want="$(awk -F'\t' -v n="$(basename "$f")" '$3==n {print $5}' "$MANIFEST" | head -1)"
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      say "   MISMATCH $(basename "$f"): manifest $want vs $got"; bad=1
    else
      say "   ok $(basename "$f")  ${got:0:16}…"
    fi
  done
  [ $bad = 0 ] || { say "[a16-bt] FATAL: a source file does not match the manifest"; exit 1; }

  sec "install into $QCA_DIR (btqca's own names)"
  install -d -m 0755 "$QCA_DIR"
  local n=0
  for f in hmtbtfw20.tlv hmtbtfw20.ver hmtnv20.bin hmtnv20.b105 hmtnv20.b107 hmtnv20.b108 hmtnv20.b10f hmtnv20.b112 hmtnv20.b3b \
           clnbtfw10.tlv clnbtnv10.bin clnbtnv10.b03 clnbtnv10.b07 clnbtnv10.b08 clnbtnv10.b0a clnbtnv10.b0d clnbtnv10.b17 bsrc_bt.bin; do
    [ -f "$BT_SRC/$f" ] || continue
    install -m 0644 "$BT_SRC/$f" "$QCA_DIR/$f" && { say "   installed $f ($(stat -c %s "$QCA_DIR/$f") bytes)"; n=$((n+1)); }
    # a compressed distro copy would shadow nothing (plain wins), but keep the tree tidy
    [ -f "$QCA_DIR/$f.zst" ] && [ ! -f "$QCA_DIR/$f.zst.a16bak" ] && mv -f "$QCA_DIR/$f.zst" "$QCA_DIR/$f.zst.a16bak"
  done
  say "[a16-bt] $n files installed.  (hmtbtfw20.tlv + hmtnv20.* is the set btqca names for a"
  say "[a16-bt]  WCN7850-class BT; the cln* set is kept alongside for other designs.)"
  say "[a16-bt] log: $LOG"
}

cmd_tty() {
  [ "$(id -u)" = 0 ] || { say "[a16-bt] FATAL: tty needs sudo"; exit 1; }
  sec "make sure the BT UART has a device node"
  local n; n="$(tty_for a98000)"
  if [ -n "$n" ]; then say "[a16-bt] tty already present: /dev/$n"; TTY="/dev/$n"; return 0; fi
  local major range
  major="$(awk '$1=="qcom_geni_uart"{print $3}' /proc/tty/drivers | head -1)"
  range="$(awk '$1=="qcom_geni_uart"{print $4}' /proc/tty/drivers | head -1)"
  if [ -z "$major" ]; then
    say "[a16-bt] the geni UART tty driver is not registered at all (/proc/tty/drivers)"
    return 1
  fi
  say "[a16-bt] qcom_geni_uart: major=$major minors=$range -- port logged as registered, no devtmpfs node"
  local m node
  for m in $(seq 0 7); do
    node="/dev/ttyHS$m"
    [ -c "$node" ] || mknod "$node" c "$major" "$m" 2>/dev/null
    if python3 -c "import os;fd=os.open('$node', os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK);os.close(fd)" 2>/dev/null; then
      say "   LIVE  $node   (major $major minor $m)"
      TTY="$node"
    else
      say "   empty $node"
      [ -c "$node" ] && rm -f "$node"
    fi
  done
  if [ -n "${TTY:-}" ] && [ -c "$TTY" ]; then
    say "[a16-bt] using $TTY"
    return 0
  fi
  say "[a16-bt] no live geni UART port: the port is announced at probe and then torn down"
  return 1
}

cmd_attach() {
  [ "$(id -u)" = 0 ] || { say "[a16-bt] FATAL: attach needs sudo"; exit 1; }
  if [ -d /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/bluetooth ]; then
    sec "serdev client present -- hci_qca owns the port, not a tty"
    say "[a16-bt] btattach is NOT the tool here (and never was): the DT's bluetooth node makes"
    say "[a16-bt] hci_qca bind through serdev and do the firmware download itself."
    cmd_status
    exit 0
  fi
  say "[a16-bt] no serdev client in the live DT: this boot cannot have Bluetooth, tty or not."
  cmd_status
  exit 1
}
cmd_btattach_legacy() {   # only useful on a DT with NO serdev client; kept for the record
  local TTY="${TTY:-/dev/ttyHS1}" SPEED="${SPEED:-3000000}"
  command -v btattach >/dev/null || { say "[a16-bt] FATAL: btattach missing (apt install bluez)"; exit 1; }
  sec "attach the QCA protocol on $TTY at $SPEED"
  pkill -f 'btattach' 2>/dev/null; sleep 1
  modprobe hci_uart 2>/dev/null || true
  : > /tmp/a16-btattach.log
  btattach -B "$TTY" -P qca -S "$SPEED" >>/tmp/a16-btattach.log 2>&1 &
  local pid=$!
  say "[a16-bt] btattach pid $pid, waiting 10 s for the firmware download"
  sleep 10
  sec "result"
  say "[a16-bt] btattach log: $(head -c 400 /tmp/a16-btattach.log | tr '\n' ' ')"
  say "[a16-bt] controllers: $(ls /sys/class/bluetooth 2>/dev/null | paste -sd' ' - || echo '(none)')"
  command -v hciconfig >/dev/null && hciconfig -a 2>/dev/null | head -12 | sed 's/^/    /' | tee -a "$LOG"
  say "[a16-bt] kernel:"; journalctl -k --since "-40s" --no-pager 2>/dev/null | grep -iE 'bluetooth|btqca|hci_uart|hci[0-9]|rampatch|patchram|qca/|nv[0-9][0-9]\.bin|firmware' | tail -20 | sed 's/^/    /' | tee -a "$LOG"
  if [ -e /sys/class/bluetooth/hci0 ]; then
    say ""
    say "[a16-bt] VERDICT: hci0 exists -- Bluetooth is up.  Next: 'bluetoothctl show', then scan."
  else
    say ""
    say "[a16-bt] VERDICT: no controller.  Read the kernel lines above: they name the file btqca"
    say "           wanted (a name we have not installed, or a rejected protocol) or the tty."
  fi
  say "[a16-bt] log: $LOG"
}

case "$MODE" in
  status)  cmd_status ;;
  rebind)  cmd_rebind ;;
  tty)     cmd_tty ;;
  install) cmd_install ;;
  attach)  cmd_attach ;;
  btattach) cmd_btattach_legacy ;;
  all)     cmd_install; cmd_rebind; cmd_tty; cmd_attach ;;
  *)       printf 'usage: %s [status|rebind|tty|install|attach|btattach|all]\n' "$0"; exit 2 ;;
esac
exit 0
