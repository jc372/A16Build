#!/usr/bin/env bash
# steps/50-bluetooth.sh -- the Bluetooth chain: firmware blobs are step 30; this step gives uart14
#                          a serdev client (a patched DTB), puts that DTB in front of the next
#                          boot, and verifies the chip afterwards.
#
#   bash steps/50-bluetooth.sh            # report: what is missing, what to run
#   sudo bash steps/50-bluetooth.sh --apply   # build + install + arm the patched DTB (then reboot)
#
# Why it is shaped like this: uart14 (a98000.serial) is a serdev *controller*, so the kernel
# hides its tty (btattach can never work); hci_uart only binds through a DT client node.  And the
# module's Bluetooth kill line (w-disable2 = TLMM 116) is held asserted by pwrseq-pcie-m2, which
# requests it GPIOD_OUT_HIGH while the DTB declares it ACTIVE_LOW -- so the patched DTB flips
# that one flags cell to ACTIVE_HIGH.  Both facts, and how they were found, are in ../README.md §1.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRINGUP="$(dirname "$HERE")"; TOOLS="$BRINGUP/tools"
MODE="${1:-report}"
LOG="${A16_LOG:-$HOME/a16-payload/A16STEP50-$(date +%Y%m%d-%H%M%S).log}"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== step 50: Bluetooth $(date +%Y%m%d-%H%M%S) ==="

live_client=0
[ -d /proc/device-tree/soc@0/geniqup@ac0000/serial@a98000/bluetooth ] && live_client=1
if command -v dtc >/dev/null 2>&1 && dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -q 'qcom,wcn7850-bt'; then
  live_client=1
fi
say "   live DT has the serdev client: $([ "$live_client" = 1 ] && echo yes || echo no)"
say "   driver version line          : $(journalctl -k -b 0 --no-pager 2>/dev/null | grep -m1 'QCA controller version' | sed 's/^.*Bluetooth: //' || echo '(none)')"
say "   controller                   : $(bluetoothctl list 2>/dev/null | grep -m1 Controller || echo '(none)')"

if [ "$live_client" = 1 ] && bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
  say ""
  say "   Bluetooth is up on this boot.  Nothing to do."
  say "   (For the record: $(journalctl -k -b 0 --no-pager 2>/dev/null | grep -m1 'QCA controller version' || echo 'no QCA version line'))"
  say "log: $LOG"; exit 0
fi

if [ "$MODE" != "--apply" ]; then
  say ""
  say "   What to run:"
  say "     sudo bash $0 --apply      # builds the patched DTB, installs it to the ESP and /boot,"
  say "                              # writes a sha256 sidecar, then arming it over the two paths"
  say "                              # entries [1]-[4] read (backups: *.a16stock)"
  say "     reboot                    # no menu interaction is needed"
  say "     bash steps/60-verify.sh"
  say ""
  say "   Read-only state first, if you want it:  bash $TOOLS/a16-bt-setup.sh status"
  say "log: $LOG"; exit 0
fi

[ "$(id -u)" = 0 ] || { say "   --apply needs root: sudo bash $0 --apply"; exit 1; }
say "   building + installing + arming (tools/a16-bt-dtb.sh --install) …"
bash "$TOOLS/a16-bt-dtb.sh" --install 2>&1 | sed 's/^/   /' | tee -a "$LOG"
rc=${PIPESTATUS[0]}
say "   a16-bt-dtb.sh rc=$rc"
[ "$rc" = 0 ] || { say "   FAILED -- read the log above (it names the file and the sha it expected)"; say "log: $LOG"; exit $rc; }

say ""
say "   Armed.  REBOOT now: any of the DT rows ([1] [2] [3] [4]) loads the patched DTB."
say "   After it comes up:  bash steps/60-verify.sh"
say "   Expect in the kernel log:  Bluetooth: hci0: QCA Product ID   :0x00000020"
say "                              Bluetooth: hci0: QCA controller version 0x21000101"
say "   To undo everything from this step:  sudo bash $TOOLS/a16-bt-arm.sh revert"
say "log: $LOG"
