#!/usr/bin/env bash
# a16-bt-dtb.sh -- give the A16's Bluetooth UART a serdev child, as a patched DTB.
#
#   bash a16-bt-dtb.sh --dry-run        # build + verify the patched DTB in /tmp, touch nothing
#   sudo bash a16-bt-dtb.sh --install   # build it, put it on the ESP and add a menu entry
#
# Why: uart14 (`a98000.serial`, the BT UART) is registered as a **serdev controller** -- its
# port device carries a `serial0` child -- so the kernel deliberately hides the tty from
# userspace and `btattach` can never open it (all 8 minors of qcom_geni_uart come back ENXIO).
# A serdev *client* is what binds hci_qca, and the DT has none: upstream's A16 DTS gives
# `&uart14` only a `port` graph child.  So add
#
#     &uart14 { bluetooth { compatible = "qcom,wcn7850-bt"; ... } }
#
# hci_qca (built into hci_uart.ko, CONFIG_BT_HCIUART_SERDEV=y) then binds and does the
# rampatch/NVM download itself -- the files the Windows package gave us, already installed
# in /lib/firmware/qca by a16-bt-setup.sh.
#
# TEST, NOT A FIX: hci_qca's wcn7850 data demands six supplies (vddio, vddaon, vdddig,
# vddrfa0p8, vddrfa1p2, vddrfa1p9) via devm_regulator_bulk_get(), and the A16's DTS describes
# none of them for the module.  This script stubs them to always-on fixed regulators: the
# driver is satisfied and the chips are (very likely) powered already, since WLAN on the same
# module works.  If the radio answers, the rails still have to be mapped for real before this
# is anything but a test.
set -u

ESP="${A16_ESP:-/boot/efi}"
ESP_DTB="$ESP/a16boot/glymur-asus-zenbook-a16-ux3607oa.dtb"
BOOT_DTB="${A16_BOOT_DTB:-/boot/glymur-asus-zenbook-a16-ux3607oa.dtb}"
TEST_DTB_NAME="glymur-a16-bt-test.dtb"
ENTRY_TITLE="[8] A16: 7.3 + glymur DTB + Bluetooth serdev test (wcn7850-bt, stubbed rails)"
KERNEL="/boot/vmlinuz-7.3.0-rc3-next-20260914"
INITRD="/boot/initrd.img-7.3.0-rc3-next-20260914"
WORK="$(mktemp -d /tmp/a16-bt-dtb-XXXXXX)"
MODE="${1:---dry-run}"
# under sudo $HOME is /root: resolve the log *after* that redirect, or the run logs where the
# invoking user cannot read it (a16-bt-setup.sh already did this; this script did not)
[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
LOG="${A16_LOG:-$HOME/a16-payload/A16BTDTB-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || { LOG=/var/tmp/a16-bt-dtb-$(date +%Y%m%d-%H%M%S).log; : > "$LOG"; }

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
die() { say "[a16-bt-dtb] FATAL: $*"; exit 1; }

say "[a16-bt-dtb] === a16-bt-dtb $MODE $(date +%Y%m%d-%H%M%S) ==="
command -v dtc >/dev/null || die "dtc missing (apt install device-tree-compiler)"

# The build source has to be the STOCK DTB: once a16-bt-arm.sh has armed the two paths the
# entries read, $ESP_DTB *is* the patched file and patching it again would nest a second
# bluetooth node.  The arm script keeps the stock original as <path>.a16stock.
SRC_DTB=""
for c in "$ESP_DTB.a16stock" "$BOOT_DTB.a16stock" "$ESP_DTB"; do
  [ -f "$c" ] || continue
  if dtc -f -I dtb -O dts "$c" 2>/dev/null | grep -q 'qcom,wcn7850-bt'; then
    say "[a16-bt-dtb] skipping $c: it already carries the bluetooth client (not a stock source)"
    continue
  fi
  SRC_DTB="$c"; break
done
[ -n "$SRC_DTB" ] || die "no stock DTB to build from (looked for $ESP_DTB.a16stock, $BOOT_DTB.a16stock, $ESP_DTB)"

sec "decompile the DTB in use"
dtc -f -I dtb -O dts -o "$WORK/orig.dts" "$SRC_DTB" 2>"$WORK/dtc-dec.err" || die "dtc decompile failed: $(tail -2 "$WORK/dtc-dec.err")"
say "[a16-bt-dtb] source  : $SRC_DTB ($(stat -c %s "$SRC_DTB") bytes, stock)"
say "[a16-bt-dtb] dts     : $(wc -l < "$WORK/orig.dts") lines, $(grep -c 'serial@a98000' "$WORK/orig.dts") uart14 node(s)"

sec "add the serdev client and the stub rails"
python3 - "$WORK/orig.dts" "$WORK/patched.dts" <<'PY' || die "patching failed"
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

BLOCK = """
/ {
	a16_bt_vddio: regulator-bt-vddio {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDIO";
		regulator-min-microvolt = <1800000>;
		regulator-max-microvolt = <1800000>;
		regulator-always-on;
	};
	a16_bt_vddaon: regulator-bt-vddaon {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDAON";
		regulator-min-microvolt = <600000>;
		regulator-max-microvolt = <600000>;
		regulator-always-on;
	};
	a16_bt_vdddig: regulator-bt-vdddig {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDDIG";
		regulator-min-microvolt = <850000>;
		regulator-max-microvolt = <850000>;
		regulator-always-on;
	};
	a16_bt_vddrfa0p8: regulator-bt-vddrfa0p8 {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDRFA0P8";
		regulator-min-microvolt = <800000>;
		regulator-max-microvolt = <800000>;
		regulator-always-on;
	};
	a16_bt_vddrfa1p2: regulator-bt-vddrfa1p2 {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDRFA1P2";
		regulator-min-microvolt = <1200000>;
		regulator-max-microvolt = <1200000>;
		regulator-always-on;
	};
	a16_bt_vddrfa1p9: regulator-bt-vddrfa1p9 {
		compatible = "regulator-fixed";
		regulator-name = "A16_BT_VDDRFA1P9";
		regulator-min-microvolt = <1900000>;
		regulator-max-microvolt = <1900000>;
		regulator-always-on;
	};
};
"""

BT = """\t\t\t\tbluetooth {
\t\t\t\t\tcompatible = "qcom,wcn7850-bt";
\t\t\t\t\tmax-speed = <3200000>;
\t\t\t\t\tvddio-supply = <&a16_bt_vddio>;
\t\t\t\t\tvddaon-supply = <&a16_bt_vddaon>;
\t\t\t\t\tvdddig-supply = <&a16_bt_vdddig>;
\t\t\t\t\tvddrfa0p8-supply = <&a16_bt_vddrfa0p8>;
\t\t\t\t\tvddrfa1p2-supply = <&a16_bt_vddrfa1p2>;
\t\t\t\t\tvddrfa1p9-supply = <&a16_bt_vddrfa1p9>;
\t\t\t\t};
"""

# find the serial@a98000 node and insert the client before its closing brace
m = re.search(r"\n(\s*)serial@a98000 \{", text)
if not m:
    sys.exit("serial@a98000 not found in the DTS")
start = m.start(1)                 # position of the node's first line
i = text.index("{", m.start())     # opening brace of the node
depth, j = 0, i
while j < len(text):
    if text[j] == "{":
        depth += 1
    elif text[j] == "}":
        depth -= 1
        if depth == 0:
            break
    j += 1
if depth != 0:
    sys.exit("unbalanced braces around serial@a98000")
text = text[:j] + BT + text[j:]
print("   inserted the bluetooth client into serial@a98000 and 6 always-on stub rails")

# --- the BT kill line: pwrseq-pcie-m2's probe level -------------------------------
# The M.2 connector node carries w-disable2-gpios (the module's Bluetooth kill line) and the
# pwrseq-pcie-m2 driver requests it with GPIOD_OUT_HIGH.  With the property's ACTIVE_LOW flag
# that initial value is a *physical LOW* = the kill line ASSERTED, and the driver only ever
# deasserts it in its "uart-enable" power-sequencing unit.  That unit runs for the serdev BT
# device the driver creates itself, which happens only for PCI IDs in its table (17cb:1103,
# 17cb:1107) -- this machine's WLAN/BT part is 17cb:1112, so the unit never runs and the line
# stays asserted.  A module whose BT core is held off answers nothing on its UART, which is
# exactly the -110 on 0xfc00 that three rebuilds of everything else failed to move.
# Flipping the one flags cell to ACTIVE_HIGH makes the driver's initial output a physical HIGH:
# the same level Windows leaves the line at.
m = re.search(r"(w-disable2-gpios\s*=\s*<)([^>]*)(>;)", text)
if not m:
    sys.exit("w-disable2-gpios is not in this DTB -- refusing to build an unpatched variant")
cells = m.group(2).split()
if len(cells) < 3:
    sys.exit("w-disable2-gpios has %d cells, expected 3 (controller, line, flags)" % len(cells))
if cells[-1] not in ("0x1", "0x01", "1"):
    sys.exit("w-disable2-gpios flags are %s, expected 0x1 (GPIO_ACTIVE_LOW)" % cells[-1])
cells[-1] = "0x0"
text = text[:m.start()] + m.group(1) + " ".join(cells) + m.group(3) + text[m.end():]
print("   w-disable2-gpios -> " + " ".join(cells) + "  (0x0 = ACTIVE_HIGH: BT kill line deasserted)")

open(dst, "w").write(text + BLOCK)
PY
grep -c 'qcom,wcn7850-bt' "$WORK/patched.dts" >/dev/null || die "the bluetooth node did not land in the DTS"
say "[a16-bt-dtb] patched : $(grep -c 'qcom,wcn7850-bt' "$WORK/patched.dts") bluetooth node, $(grep -c 'regulator-bt-' "$WORK/patched.dts") stub rails"

sec "compile and verify"
dtc -f -I dts -O dtb -o "$WORK/$TEST_DTB_NAME" "$WORK/patched.dts" 2>"$WORK/dtc-comp.err" || die "dtc compile failed: $(tail -3 "$WORK/dtc-comp.err")"
say "[a16-bt-dtb] compiled: $(stat -c %s "$WORK/$TEST_DTB_NAME") bytes, sha256 $(sha256sum "$WORK/$TEST_DTB_NAME" | cut -c1-16)"
dtc -f -I dtb -O dts -o "$WORK/verify.dts" "$WORK/$TEST_DTB_NAME" 2>/dev/null
for want in 'qcom,wcn7850-bt' 'vddrfa1p9-supply' 'regulator-always-on' 'qcom,geni-uart' 'qcom,geni-debug-uart'; do
  if grep -q "$want" "$WORK/verify.dts"; then say "   present : $want"; else say "   MISSING : $want"; fi
done
say "   model   : $(grep -m1 'model = ' "$WORK/verify.dts" | tr -d '\t;' | sed 's/model = //')"
say "   uart14 still okay: $(grep -A22 'serial@a98000' "$WORK/verify.dts" | grep -m1 'status' | tr -d '\t;')"
WDS="$(grep -m1 'w-disable2-gpios' "$WORK/verify.dts" | tr -d '\t;' | sed 's/^ *//')"
if printf '%s' "$WDS" | grep -qE '<0x[0-9a-f]+ 0x[0-9a-f]+ 0x0+>$'; then
  say "   $WDS   <- kill line deasserted at pwrseq probe (BT allowed)"
else
  die "the w-disable2 flags cell did not come back as ACTIVE_HIGH -- got: $WDS"
fi
DTB_SHA="$(sha256sum "$WORK/$TEST_DTB_NAME" | cut -d' ' -f1)"
printf '%s  %s\nvariant: serdev bluetooth client on uart14 + 6 always-on stub rails + w-disable2-gpios flipped to ACTIVE_HIGH (BT kill line deasserted)\n' \
  "$DTB_SHA" "$TEST_DTB_NAME" > "$WORK/$TEST_DTB_NAME.sha256"

if [ "$MODE" != "--install" ]; then
  sec "dry run -- nothing installed"
  cp -f "$WORK/$TEST_DTB_NAME" "$HOME/a16-payload/$TEST_DTB_NAME"
  cp -f "$WORK/$TEST_DTB_NAME.sha256" "$HOME/a16-payload/$TEST_DTB_NAME.sha256"
  say "[a16-bt-dtb] built artifact kept at $HOME/a16-payload/$TEST_DTB_NAME"
  say "[a16-bt-dtb] sha256 $DTB_SHA"
  say "[a16-bt-dtb] log: $LOG"
  exit 0
fi

[ "$(id -u)" = 0 ] || die "--install needs root"
sec "install the DTB and add the menu entry"
install -m 0644 "$WORK/$TEST_DTB_NAME" "$ESP/a16boot/$TEST_DTB_NAME" || die "copy to the ESP failed"
install -m 0644 "$WORK/$TEST_DTB_NAME.sha256" "$ESP/a16boot/$TEST_DTB_NAME.sha256"
say "[a16-bt-dtb] ESP   : $ESP/a16boot/$TEST_DTB_NAME  (sha256 $DTB_SHA)"
if [ -f "$BOOT_DTB" ]; then
  install -m 0644 "$WORK/$TEST_DTB_NAME" "/boot/$TEST_DTB_NAME" && say "[a16-bt-dtb] /boot : /boot/$TEST_DTB_NAME"
  install -m 0644 "$WORK/$TEST_DTB_NAME.sha256" "/boot/$TEST_DTB_NAME.sha256"
else
  say "[a16-bt-dtb] no $BOOT_DTB, skipping the /boot copy"
fi
install -m 0644 "$WORK/$TEST_DTB_NAME" "$HOME/a16-payload/$TEST_DTB_NAME" 2>/dev/null || true
install -m 0644 "$WORK/$TEST_DTB_NAME.sha256" "$HOME/a16-payload/$TEST_DTB_NAME.sha256" 2>/dev/null || true

ENTRY_BODY=$(cat <<EOF

menuentry "$ENTRY_TITLE" {
    echo "  prefix=\$prefix  cmdpath=\$cmdpath"
    echo "  serdev bluetooth client for uart14; the six module rails are stubbed always-on"
    search --no-floppy --fs-uuid --set=root f8e005e9-414c-4c8e-ad68-d1e9fdc208bc
    if [ -f $KERNEL -a -f $INITRD ]; then
        insmod fdt
        insmod gzio
        linux $KERNEL root=UUID=f8e005e9-414c-4c8e-ad68-d1e9fdc208bc  ro  acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20 modprobe.blacklist=msm console=tty0 keep_bootcon loglevel=7 crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M
        devicetree /boot/$TEST_DTB_NAME
        initrd $INITRD
        boot
    fi
    echo "  kernel files missing"
    sleep 20
    configfile \$prefix/grub.cfg
}
EOF
)
n=0
for cfg in "$ESP/a16boot/grub.cfg" "$ESP/EFI/Boot/grub.cfg" "$ESP/EFI/ubuntu/grub.cfg" "$ESP/EFI/ubuntu_snapdragon/grub.cfg"; do
  [ -f "$cfg" ] || continue
  # grep -F, and key on the DTB filename rather than the title: $ENTRY_TITLE starts with
  # "[8]", which a basic regex reads as a character class, so the old check never matched and
  # every run appended another copy of the entry.
  if grep -Fq "$TEST_DTB_NAME" "$cfg"; then say "   $cfg already loads $TEST_DTB_NAME"; continue; fi
  cp -a "$cfg" "$cfg.a16bak-$(date +%Y%m%d-%H%M%S)"
  printf '%s' "$ENTRY_BODY" >> "$cfg" || { say "   FAILED to append to $cfg"; continue; }
  say "   $cfg : entry appended (backup kept)"
  n=$((n+1))
done
grub-script-check "$ESP/a16boot/grub.cfg" 2>&1 | head -3 || true
say "[a16-bt-dtb] $n config file(s) updated"
say ""

# Hand the new artifact to the two paths the DT entries actually read, so the next boot gets it
# without anybody touching the menu (this is what the last two reboots failed to do).
ARM="$HOME/a16-payload/a16-bt-arm.sh"
if [ -f "$ARM" ]; then
  sec "arm the paths entries [1]-[4] load"
  bash "$ARM" arm 2>&1 | sed 's/^/   /'
  say "[a16-bt-dtb] (a16-bt-arm.sh rc=$?)"
else
  say "[a16-bt-dtb] no $ARM -- run it yourself, or the menu entry is the only route"
fi
say ""
say "[a16-bt-dtb] NEXT: reboot (no menu interaction needed), then:"
say "               bash /home/jc/a16-payload/a16-bt-setup.sh status"
say "[a16-bt-dtb] Expect: serdev client PRESENT, 6 of 6 stub rails, then either hci0 in"
say "[a16-bt-dtb] /sys/class/bluetooth with a name, or the qca firmware lines naming what it"
say "[a16-bt-dtb] asked for.  'command 0xfc00 tx timeout' again means the kill line was not it."
say "[a16-bt-dtb] log: $LOG"
exit 0
