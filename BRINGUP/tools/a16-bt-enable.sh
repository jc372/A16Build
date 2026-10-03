#!/usr/bin/env bash
# a16-bt-enable.sh -- test the one hardware hypothesis left for the A16's Bluetooth: the
#                     module's BT core is held disabled by the connector's W_DISABLE2# line.
#
# SUPERSEDED for the current blocker (the line is owned by pwrseq-pcie-m2, so the export
# below returns EBUSY); kept as the probe for the kill lines.  See a16-bt-dtb.sh.
#
#   sudo bash a16-bt-enable.sh            # probe (default): read the state, deassert the
#                                         #   disable lines, retry the BT power-on, report
#   sudo bash a16-bt-enable.sh status     # read-only: the same state, nothing touched
#   sudo bash a16-bt-enable.sh off        # unexport the lines this script exported
#
# Why this, and not more DTB guesswork: the machine DTB describes the WCN module as an M.2
# module connector and names the two disable lines on it:
#
#   wlan-connector {                        // compatible = "pcie-m2-e-connector"
#       vpcie3v3-supply  = <regulator-wcn-3p3>;      // VREG_WCN_3P3, switched by GPIO94
#       w-disable1-gpios = <&tlmm 117 GPIO_ACTIVE_LOW>;
#       w-disable2-gpios = <&tlmm 116 GPIO_ACTIVE_LOW>;
#       pinctrl-0 = <wcn-wlan-bt-en-state>;          // pins 116+117 muxed as GPIO outputs
#   };
#
# W_DISABLE2# is the module's Bluetooth kill line; being active-low, BT is *allowed* when the
# pin is HIGH.  No driver in this tree claims the "pcie-m2-e-connector" node, so that pin holds
# whatever level the firmware left it at and its pin state is never applied -- which is how a
# chip that is powered and wired can still answer nothing at all on its UART.  The WLAN half of
# the same module works, so the shared 3.3 V rail (GPIO94, boot-on) is on.
#
# GPIO 116 = sysfs line <tlmm base>+116, 117 = +117, 94 = +94.  The line numbers are absolute
# in /sys/class/gpio (TLMM is gpiochip512 here, so 628/629/606) -- the script reads the base.
#
# Nothing here survives a reboot: if this makes hci0 appear, the fix has to be baked into the
# patched DTB (a gpio-hog on the pin) and that is a separate script.

set -u
MODE="${1:-probe}"

if [ "$(id -u)" != 0 ]; then
  echo "needs root (both reading /sys/kernel/debug and /sys/class/gpio do):  sudo bash $0 $MODE" >&2
  exit 1
fi
[ -n "${SUDO_USER:-}" ] && HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
LOG="${A16_LOG:-$HOME/a16-payload/A16BTEN-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || LOG="/var/tmp/a16-bt-enable-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG="/var/tmp/a16-bt-enable-$(date +%Y%m%d-%H%M%S).log"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
dump() { sed 's/^/    /' | tee -a "$LOG"; }

say "[a16-bt-en] === a16-bt-enable $MODE $(date +%Y%m%d-%H%M%S) ===  (root=yes)"

# ---------------------------------------------------------------- the lines, by name
TLMM_BASE=""
for d in /sys/class/gpio/gpiochip*/; do
  [ -e "$d/label" ] || continue
  [ "$(cat "$d/label")" = "f100000.pinctrl" ] && TLMM_BASE="$(cat "$d/base")"
done
[ -n "$TLMM_BASE" ] || { say "[a16-bt-en] FATAL: no gpiochip labelled f100000.pinctrl"; exit 1; }
L94=$((TLMM_BASE + 94)); L116=$((TLMM_BASE + 116)); L117=$((TLMM_BASE + 117))
say "[a16-bt-en] TLMM gpiochip base $TLMM_BASE -> wcn_3v3_en=$L94  w_disable2(BT)=$L116  w_disable1(WLAN)=$L117"

# debugfs shows *claimed* lines only; a line that is absent is claimed by nobody, which is
# itself the evidence.  Reading it this way requests nothing, so the pads do not glitch.
[ -d /sys/kernel/debug/gpio ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
line_state() {   # <abs line> -> "claimed: <consumer> <dir> <level>" | "claimed by nothing"
  local l="$1" s
  s="$(grep -m1 "gpio-$l " /sys/kernel/debug/gpio 2>/dev/null)"
  [ -n "$s" ] && printf 'claimed: %s' "$(printf '%s' "$s" | sed 's/^gpio-[0-9]* *//; s/  */ /g')" || printf 'claimed by nothing'
}

show_state() {
  sec "the three lines"
  say "[a16-bt-en] $L94  (wcn 3v3 enable) : $(line_state "$L94")"
  say "[a16-bt-en] $L116 (w_disable2 / BT) : $(line_state "$L116")"
  say "[a16-bt-en] $L117 (w_disable1/WLAN): $(line_state "$L117")"
  sec "pads, as the pin controller sees them"
  local pd=/sys/kernel/debug/pinctrl/f100000.pinctrl
  if [ -r "$pd/pinmux-pins" ]; then
    for p in 94 116 117; do say "[a16-bt-en] pin $p : $(grep -m1 -E "^pin $p " "$pd/pinmux-pins" | sed 's/^ *//')"; done
    say "[a16-bt-en] pinctrl debugfs: $(ls "$pd" | paste -sd' ' -)"
  else
    say "[a16-bt-en] no pinctrl debugfs at $pd"
  fi
  sec "the module's rails + what hci_qca has said"
  grep -E 'VREG_WCN_3P3|regulator-bt-|regulator-wcn' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -10 | dump
  say "[a16-bt-en] controllers: $(ls /sys/class/bluetooth 2>/dev/null | paste -sd' ' - || echo none)   serdev driver: $(basename "$(readlink -f /sys/bus/serial/devices/serial0-0/driver 2>/dev/null)" 2>/dev/null || echo none)"
  journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE 'qca|hci0|serdev' | grep -viE 'xhci' | tail -8 | dump
}

if [ -d /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/bluetooth ]; then
  say "[a16-bt-en] serdev client node present (patched DTB is live)"
else
  say "[a16-bt-en] WARNING: no serdev client node -- the armed DTB is not live; arm it first"
  say "[a16-bt-en]          (sudo bash $HOME/a16-payload/a16-bt-arm.sh) or nothing below applies"
fi

if [ "$MODE" = status ]; then show_state; say ""; say "[a16-bt-en] log: $LOG"; exit 0; fi

if [ "$MODE" = off ]; then
  for l in $L116 $L117; do
    [ -d "/sys/class/gpio/gpio$l" ] && { echo "$l" > /sys/class/gpio/unexport 2>/dev/null && say "[a16-bt-en] unexported $l (pad returns to its default state)"; }
  done
  say "[a16-bt-en] log: $LOG"; exit 0
fi

# ---------------------------------------------------------------- probe
show_state

drive() {   # <abs line> <0|1> -> drives it, prints the result
  local l="$1" v="$2"
  [ -d "/sys/class/gpio/gpio$l" ] || echo "$l" > /sys/class/gpio/export 2>/dev/null
  if [ ! -d "/sys/class/gpio/gpio$l" ]; then
    printf 'EXPORT FAILED (%s)' "$(line_state "$l")"
    return 1
  fi
  echo out > "/sys/class/gpio/gpio$l/direction" 2>/dev/null || { printf 'direction failed'; return 1; }
  echo "$v" > "/sys/class/gpio/gpio$l/value" 2>/dev/null || { printf 'value write failed'; return 1; }
  printf 'ok, reads back %s (%s)' "$(cat "/sys/class/gpio/gpio$l/value" 2>/dev/null)" "$(line_state "$l")"
}

retry_bt() {
  local drv=/sys/bus/serial/drivers/hci_uart_qca dev=serial0-0
  [ -w "$drv/unbind" ] || { say "[a16-bt-en] no $drv/unbind -- cannot re-probe the driver"; return 1; }
  echo "$dev" > "$drv/unbind" 2>/dev/null && say "[a16-bt-en] unbound $dev"
  sleep 1
  echo "$dev" > "$drv/bind" 2>/dev/null && say "[a16-bt-en] re-bound $dev -- qca_setup runs again"
  sleep 12
  say "[a16-bt-en] controllers after the re-probe: $(ls /sys/class/bluetooth 2>/dev/null | paste -sd' ' - || echo none)"
  journalctl -k --since "-25s" --no-pager 2>/dev/null | grep -iE 'qca|hci0|serdev|wcn' | tail -8 | dump
}

sec "deassert both disable lines (active-low: 1 = allowed, and 1 is the level the module wants)"
say "[a16-bt-en] drive $L116 = 1 -> $(drive "$L116" 1)"
say "[a16-bt-en] drive $L117 = 1 -> $(drive "$L117" 1)"
sec "re-probe the BT driver"
retry_bt

# hci0 exists as soon as the serdev client binds, even when power-on fails, so the
# verdict is the *address* hci_qca sets once it has talked to the chip.
controller_up() { bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; }   # sysfs has no address attr here
if controller_up; then
  sec "VERDICT: the controller is up -- the W_DISABLE2 line was the blocker"
  say "[a16-bt-en] name: $(cat /sys/class/bluetooth/hci0/name 2>/dev/null || echo '(not readable yet)')"
  say "[a16-bt-en] Bluetooth works for the rest of this boot.  It is NOT persistent: a sysfs"
  say "[a16-bt-en] export dies with the reboot.  The permanent form is a gpio-hog on pin 116 in"
  say "[a16-bt-en] the patched DTB -- say so and that is the next script."
  say "[a16-bt-en] log: $LOG"
  exit 0
fi

sec "no controller at 1/1 -- try the opposite level on 116, in case this pad is not active-low"
say "[a16-bt-en] drive $L116 = 0 -> $(drive "$L116" 0)"
retry_bt
if controller_up; then
  sec "VERDICT: the controller came up with $L116 driven LOW"
  say "[a16-bt-en] so pin 116 is an active-high BT enable, not a W_DISABLE# line.  Say so; the"
  say "[a16-bt-en] DTB hog then drives it high instead.  (Still not persistent.)"
  say "[a16-bt-en] log: $LOG"
  exit 0
fi

sec "VERDICT: no controller with the disable line driven either way"
say "[a16-bt-en] Read the dump above; it separates the three remaining cases:"
say ""
say "  * A line still reported as 'claimed by nothing' AFTER we exported it means the write did"
say "    not stick, and the pad may not be muxed as GPIO (check the 'function' in the pinmux"
say "    lines: it must be gpio, not something else).  Wrong mux = DTB work, not userspace."
say "  * A line we could not export at all means a driver owns it; that driver is then the thing"
say "    to read, and its binding decides whether BT can come up."
say "  * Pins free, driven, chip still silent (-110 on 0xfc00, 'Retry BT power ON') means the BT"
say "    core needs something else.  The next real evidence is the firmware's own description of"
say "    the BT UART: Windows binds 'Qualcomm(R) Bluetooth UART Transport Driver' at"
say "    ACPI\\QCOM0F6B and 'FastConnect C7700 NCM820A Bluetooth Adapter' (QCA_SHB\\UART_H4_CLG)."
say "    Booting the ACPI row [0] lets us copy /sys/firmware/acpi/tables/DSDT out and read"
say "    QCOM0F6B's _CRS/_DSD: the UART base it uses, and any GPIO it is told to drive."
say ""
say "[a16-bt-en] Restoring the levels and releasing the lines:"
say "[a16-bt-en] $(drive "$L116" 1 >/dev/null 2>&1; echo "116 exported=$([ -d /sys/class/gpio/gpio$L116 ] && echo yes || echo no)")"
say "[a16-bt-en] pins stay exported so you can watch them; 'sudo bash $0 off' releases them."
say "[a16-bt-en] log: $LOG"
exit 1
