# 2026-09-16 — Bluetooth on the A16: transport found, firmware installed, tty missing

Author: Hermes
Date: 2026-09-16
Project: A16Build (ASUS Zenbook A16 UX3607OA, Snapdragon X2 Elite, Glymur)

## What the machine describes

- The BT radio hangs off `uart14` = `/soc@0/geniqup@ac0000/serial@a98000` (DT alias `serial1`),
  `status = "okay"`, wired by a graph port to the `wlan-connector` (M.2-E socket). Windows names
  the same device `QCA_SHB\UART_H4_CLG\…` (QCA serial hub, HCI H4 over UART), bound INF
  `oem138.inf` -> package `qcbluetooth8480`.
- Upstream's A16 DTS has **no Bluetooth child node** under `&uart14` (only the graph `port`),
  and no sibling glymur board describes BT either — the same class of gap as the missing Wi-Fi
  node, and the reason nothing binds.

## Firmware: the missing half is in our own extraction

The kernel's `btqca` builds `qca/hmtbtfw%02x.tlv` + `qca/%s%02x%s.bin` (stem `hmtnv`) for a
WCN7850-class BT, and `hci_qca` supports `qcom,wcn7850-bt`. `/lib/firmware/qca` ships only the
`hp*` family, while the Windows package `qcbluetooth8480` ships exactly the hmt set:

    hmtbtfw20.tlv 280,764 B   hmtnv20.bin + b105/b107/b108/b10f/b112/b3b (9,656 B each)
    (plus the cln* family: clnbtfw10.tlv, clnbtnv10.b* — kept alongside)

Installed and manifest-verified by `scripts/a16-bt-setup.sh install` (10 files).

## The blocker: the BT UART has no tty

    a98000(BT)=none  894000(debug)=ttyMSM0
    boot log: "a98000.serial: ttyHS1 MMIO:0x00000000a98000 ... is a MSM"
              "serial serial0: tty port ttyHS1 registered"

The port was registered at boot and is gone now: the device is bound to `qcom_geni_serial`
with no tty child (its sibling UART keeps `ttyMSM0`), so `btattach` has nothing to open.
Possible cause: two builtin drivers (`CONFIG_SERIAL_MSM=y` and `CONFIG_SERIAL_QCOM_GENI=y`)
both claiming the geni nodes at boot; the msm port is then torn down when geni takes over.

Next, in order:
1. `sudo bash scripts/a16-bt-setup.sh rebind` — unbind/bind `a98000.serial` and look for a tty.
2. If a tty appears: `sudo bash scripts/a16-bt-setup.sh attach` (btattach -P qca at 3 Mbaud).
3. If not: the DTB route — add `&uart14 { bluetooth { compatible = "qcom,wcn7850-bt";
   max-speed = <3200000>; ... } }`. The kernel has `CONFIG_SERIAL_DEV_BUS=y` and
   `CONFIG_BT_HCIUART_SERDEV=y`, so serdev would bind it; the driver wants six supplies
   (vddio, vddaon, vdddig, vddrfa0p8, vddrfa1p2, vddrfa1p9) and the A16 DTS currently names
   only `vreg_wcn_3p3` (3.3 V, GPIO 94 enable) for the module — those rail names must be
   mapped from the PMIC descriptions before the node can be trusted.

## Root cause of the "no tty" (found after the first attempts)

`uart14` is a **serdev controller**, not a plain UART: its port device
`/sys/devices/platform/soc@0/ac0000.geniqup/a98000.serial/a98000.serial:0/a98000.serial:0.0/`
carries a `serial0` child, so the kernel hides the tty from userspace by design. That is why
`/dev/ttyHS1` never appears, why all eight minors of `qcom_geni_uart` (major 237) return ENXIO
even right after a successful unbind/bind, and why `btattach` can never work here. The DT gives
`&uart14` only a `port` graph child — no serdev *client*, so nothing binds.

`scripts/a16-bt-dtb.sh` builds a patched DTB: it decompiles the DTB in use with `dtc`, inserts
`bluetooth { compatible = "qcom,wcn7850-bt"; max-speed = <3200000>; ... }` into `serial@a98000`,
adds six `regulator-fixed` stubs (the driver's `devm_regulator_bulk_get()` requires
vddio/vddaon/vdddig/vddrfa0p8/vddrfa1p2/vddrfa1p9 and the A16 describes none of them for the
module), recompiles, verifies by decompiling the result, then installs it as
`glymur-a16-bt-test.dtb` on the ESP (/a16boot + /boot) and appends a menu entry cloning the
working DT entry. `--dry-run` builds and verifies without touching anything (verified: 163,093 B,
sha256 e9692e4d…, `qcom,wcn7850-bt` present, uart14 still `okay`).

Checks done first: the uart14 pin state carries all four pins (`gpio56` cts, `gpio57` rts,
`gpio58` tx, `gpio59` rx, function `qup1_se6`), so flow control is safe; hci_qca's `enable` /
`sw_ctrl` GPIOs are optional; the rails are the only hard requirement.

**Status: test, not a fix.** The stub rails satisfy the driver without controlling real
hardware — legitimate only as a probe, since WLAN on the same module is powered. If the radio
answers, the rails have to be mapped for real before this is anything but a test.

## Why "reboot and pick [8]" did not work, and what replaces it

Two reboots after the 16:00 install (16:01 and 16:10) still came up on the stock DTB, proven
by decompiling the live tree: no `bluetooth` child under uart14, zero `regulator-bt-*` nodes,
and the live DT byte-identical to the stock `glymur-asus-zenbook-a16-ux3607oa.dtb`
(sha256 ddb423f8…) once bootargs/kaslr-seed/uefi-mmap are discounted.

The menu config (`set timeout=30`, `set timeout_style=menu`, `set default=1`) cannot be told
apart from entry [8] by cmdline: [1], [2] and [8] carry the *identical* kernel command line.
The DTB is therefore the only evidence of which row ran — and it says the default row did.
The trap in the menu is that the *titles* are labelled [0]…[8] while GRUB counts rows from 1,
so a numeral pressed to "pick 8" lands on the [7] row.

`scripts/a16-bt-arm.sh` removes the menu from the critical path: entries [1]–[4] read the
stock DTB from `/boot/…` and `/boot/efi/a16boot/…`, so the script backs both up to
`<path>.a16stock` (once, never overwritten) and installs the patched DTB over them.  Whichever
DT row the machine takes, it gets the serdev client.  `revert` restores the stock file and
verifies sha256; both directions refuse to run unless the file they are about to write matches
the expected sha.  Verified in a sandbox over copies of both paths: stock ddb423f8… ->
patched e9692e4d… -> stock again, `.a16stock` left intact, second `arm` idempotent.

The driver side was checked properly this time rather than assumed: `hci_uart.ko` carries
`alias: of:N*T*Cqcom,wcn7850-bt`, `CONFIG_BT_HCIUART_QCA=y` (hci_qca is inside hci_uart, not a
separate module), and `btqca.ko` is installed.  So the missing piece really is the DT node.

## Armed DTB result: the serdev client works, the chip is mute

First boot on the armed DTB (boot 16:22): `stub rails: 6 of 6`, the `bluetooth` child is in the
live tree, `/sys/class/bluetooth/hci0` exists, and `/sys/bus/serial/devices/serial0-0` is bound
to driver `hci_uart_qca` — so the DT node, the serdev bind and the module load all landed.  The
chip itself answers nothing:

    Bluetooth: hci0: setting up wcn7850
    Bluetooth: hci0: command 0xfc00 tx timeout
    Bluetooth: hci0: Reading QCA version information failed (-110)
    Bluetooth: hci0: Retry BT power ON:0 / :1 / :2
    Bluetooth: hci0: AOSP get vendor capabilities (-110)

`0xfc00` is the ROM-version read, the first thing hci_qca sends.  No reply at all, three times,
so the transport is either not reaching the chip or the chip's BT core is held off.

### What Windows says the part is

`firmware/windows-driverstore-2026-09-16/host-inventory/windows-device-inventory.txt`:

    Qualcomm FastConnect C7700 NCM820A Bluetooth Adapter   oem138.inf   QCA_SHB\UART_H4_CLG\...
    Qualcomm(R) Bluetooth UART Transport Driver            oem113.inf   ACPI\QCOM0F6B\2&DABA3FF&0
    Qualcomm(R) Aqstic(TM) BT ACX Transport Device         ACPI\QCOM0FEA\0

So the BT is the **C7700 / NCM820A** (the same FastConnect part as the WLAN, which works) and
"CLG" = **Cologne**.  The Windows package ships *both* naming families — `hmtbtfw20.tlv` +
`hmtnv20.b*` (WCN7850/"hmt") and `clnbtfw10.tlv` + `clnbtnv10.b03/b17` (Cologne/"cln").

### The remaining gap is real and it is driver work, not configuration

This kernel's `btqca.ko` knows the naming paths `hp ht cm cr ap ms wcnhp hmt` and the chip
families up to `QCA_WCN7850`.  There is **no `cln`/Cologne path and no NCM/C7700/Cologne string
anywhere in `btqca.ko` or `hci_uart.ko`** (checked with `strings`).  So if the chip turns out to
report a Cologne ROM version it will ask for `qca/clnbtfw10.tlv` + `qca/clnbtnv10.b<id>` and this
btqca has no code path that can name those.  Both files are already installed in `/lib/firmware/qca`,
so the gap would be entirely in the driver's chip table + naming, i.e. a kernel patch (or a newer
tree if upstream added Cologne).  Do not spend more boots re-testing configuration if the log
shows a version it cannot name.

### The one hardware lever worth testing: W_DISABLE2# (GPIO 116)

The machine DTB's `wlan-connector` node (`compatible = "pcie-m2-e-connector"`) names the module's
two kill lines and the shared rail:

    vpcie3v3-supply  = <regulator-wcn-3p3>;                  // = GPIO94, regulator-boot-on
    w-disable1-gpios = <&tlmm 117 GPIO_ACTIVE_LOW>;          // W_DISABLE1# (WLAN)
    w-disable2-gpios = <&tlmm 116 GPIO_ACTIVE_LOW>;          // W_DISABLE2# (Bluetooth)
    pinctrl-0        = <wcn-wlan-bt-en-state>;               // pins 116+117 as GPIO outputs

No driver in this tree claims that node, so those pins hold whatever the firmware left, and the
pin state is never applied.  W_DISABLE2# active-low means BT is *allowed* when pin 116 is HIGH —
if it is held low (or left floating), the module's BT core stays off and the UART is mute, which
is exactly what is observed.  `scripts/a16-bt-enable.sh` reads the state from debugfs (claiming
nothing, so the pads do not glitch), drives 116/117 through sysfs, re-probes `hci_uart_qca` and
reports.  It is deliberately not persistent — a win has to be baked into the patched DTB as a
gpio-hog, because nothing else claims those lines.

## Found it: the module's BT kill line was held asserted by the M.2 power sequencer

The `wlan-connector` node in the machine DTB is bound by **`pwrseq-pcie-m2`**
(`drivers/power/sequencing/pwrseq-pcie-m2.c`, `compatible = "pcie-m2-e-connector"`), and that
driver owns exactly the two lines the DTB names:

    ctx->w_disable1_gpio = devm_gpiod_get_optional(dev, "w-disable1", GPIOD_OUT_HIGH);
    ctx->w_disable2_gpio = devm_gpiod_get_optional(dev, "w-disable2", GPIOD_OUT_HIGH);
    ...
    pwrseq_pci_m2_e_uart_enable():  gpiod_set_value_cansleep(ctx->w_disable2_gpio, 0);
    pwrseq_pci_m2_e_pcie_enable():  gpiod_set_value_cansleep(ctx->w_disable1_gpio, 0);

`w_disable2` is the **UART (Bluetooth)** target, `w_disable1` is the PCIe (WLAN) one.  Both are
declared `GPIO_ACTIVE_LOW` in the DTB, so `GPIOD_OUT_HIGH` at probe time means *logical* 1 =
**physical LOW** = the kill line asserted: the BT core is held off from the moment the driver
probes.  The driver only deasserts it inside its `uart-enable` power-sequencing unit, and that
unit runs for the serdev BT device the driver creates **itself** — which it builds only for PCI
IDs in its table (`17cb:1103`, `17cb:1107`).  This machine's WLAN/BT part is `17cb:1112`
(FastConnect C7700 / NCM820A, `ath12k` claims it), so no such device is created, no consumer ever
enables the unit, and the line stays asserted.  A powered module whose BT core is held off answers
nothing on its UART: that is the `0xfc00 tx timeout` / `-110` that survived three rounds of
firmware, DTB and module work.

Why the WLAN is unaffected: the PCIe target *does* have a consumer (the PCI device itself, through
`pci-pwrctrl-pwrseq`), so `w_disable1` gets deasserted when the PCIe link is powered up.

The fix is one cell in the patched DTB: `w-disable2-gpios = <&tlmm 116 GPIO_ACTIVE_LOW>` ->
`ACTIVE_HIGH`, so the driver's initial output is a physical HIGH — the level Windows leaves the
line at.  `scripts/a16-bt-dtb.sh` now rewrites that cell (and refuses to build if it cannot find
the property or the flags are not what it expects), builds from the *stock* DTB
(`*.a16stock`, never from an already-armed file — patching a patched DTB would nest a second
bluetooth node), writes a sha256 sidecar beside the artifact, and with `--install` also runs
`a16-bt-arm.sh` so the two paths the DT entries read get the new build in one command.
`scripts/a16-bt-arm.sh` takes its expected sha from that sidecar.

Also recorded, so it is not chased again: `scripts/a16-bt-enable.sh`'s userspace poke of pin 116
cannot work — the line is already owned by `pwrseq-pcie-m2`, so the sysfs export returns EBUSY —
and `hci0` appearing is not a verdict, because the serdev bind creates it even when power-on
fails (that misreport is fixed: the verdict is now a non-empty `/sys/class/bluetooth/hci0/address`).
The `WARNING: drivers/regulator/core.c:2675 at _regulator_put` on unbind comes from hci_qca's
`devm_regulator_bulk_free` releasing the six stub rails; cosmetic, driver-side, not a clue.
