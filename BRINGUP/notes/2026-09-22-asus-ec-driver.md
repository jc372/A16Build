# 2026-09-22 — the ASUS Zenbook A16 Embedded Controller (posted 2026-09-17), brought in

## What arrived, and where

"[PATCH 0/3] Asus Zenbook A16/A14 (UX3607OA/UX3407NA) EC driver", Konrad Dybcio, 2026-09-17:

    https://lore.kernel.org/lkml/20260917-topic-asus_ec-v1-0-373516d347ae@oss.qualcomm.com/

    [PATCH 1/3] dt-bindings: embedded-controller: Add ASUS Zenbook A16 EC  (asus,zenbook-a16-ux3607oa-ec.yaml)
    [PATCH 2/3] platform: arm64: Add a driver for the EC found on ASUS Glymur machines
                 drivers/platform/arm64/asus-glymur-ec.c, 592 lines, Kconfig symbol EC_ASUS_GLYMUR
    [PATCH 3/3] arm64: dts: qcom: glymur-zenbook-a16: Add Embedded Controller  (13 lines, &i2c9)

It is for **this machine** by name, and it describes an EC that this machine has and Linux has never
talked to: I2C address `0x76` on i2c9 (`/soc@0/geniqup@ac0000/i2c@a84000`), event interrupt on TLMM
GPIO 66 (`IRQ_TYPE_EDGE_FALLING`), `wakeup-source`, `#thermal-sensor-cells = <1>`.

What the driver does:

* fan RPM for the two fans (`ASUS_QCOM_EC_RAM_FAN_CPU` 0x0602, `…_FAN_GPU` 0x0624) and two
  temperature sensors, exposed through hwmon;
* keyboard backlight (`asus::kbd_backlight`), through the LED class;
* the EC **mailbox** — page `MAILBOX`, registers `CMD` 0x30 / `SUBCMD` 0x31 / `DATA` 0x32 on the
  subdevice at 0x5b — used to send commands to the EC.  `asus_ec_enable_writes()` sends
  `ASUS_EC_MBOX_CMD_MISC` 0x02 / `…_SUBCMD_MISC_ENABLE` 0x83 at probe; the driver's own message
  calls that "enable EC direct access", and the probe aborts if it fails, so a bound driver is
  proof it worked.  The keyboard backlight level goes through the same mailbox
  (`…_CMD_KBD` 0x01 / `…_SUBCMD_KBD_LVL` 0x87);
* an **event path** — the EC raises an interrupt on GPIO 66, and `asus_ec_irq()` reads
  `ASUS_QCOM_EC_EVENT_CMD` 0x05 and logs the code at `dev_dbg`: hotkey, fan status, thermal trip,
  critical trip, thermistor.  Nothing prints at the default log level, so this path is invisible
  unless `dev_dbg` is on;
* **system suspend entry/exit are reported to the EC** — `ASUS_QCOM_EC_MODERN_STANDBY_CMD` 0x23 with
  `…_ENTER` 0x07 / `…_EXIT` 0x08, sent from the driver's `suspend`/`resume` callbacks.

State of the series: **v1, under review, not merged.**  Krzysztof Kozlowski has open questions on the
bindings (the two `compatible` strings are listed even though their compatibility is not claimed);
Abel Vesa has given a `Reviewed-by` on the DTS patch.  It is in neither linux-next master nor our
pinned tree as a driver — although the machine's DTS *already* carries the EC's pin state
(`ec_int_n_default`, gpio66) and the comments `/* EC subdevice @ 0x5b */ /* EC @ 0x76 */`, i.e. the
node was deliberately left out until this driver existed.

## Why it is more than fans and temperatures

This machine runs `acpi=off` and has **no EC driver at all**, so nothing has ever told the EC that the
system is going to standby.  The Wi-Fi failure is a suspend failure: after the first deep suspend the
QCC2072 is no longer running its firmware (`mhi0: Wait for device to enter SBL or Mission mode`, then
the 20 s timeout — `notes/2026-09-22-wifi-suspend-ladder.md`).  The EC owns platform power on these
designs, which makes "the EC was never told" a prime suspect for the module losing power across a
suspend — and the driver's suspend/resume callbacks are the only way to tell it.  So this is a
candidate **fix** for the Wi-Fi wedge, and a cheap one to test: install, reboot, suspend, see whether
the radio survives (`sudo bash ~/a16.sh wifisleep test`).

## What was done here, and what is verified

* The three patches are carried as `BRINGUP/patches/0011..0013` and **apply cleanly** to the tree this
  kernel was built from (`~/build/linux-next-1a1de54f7369`, commit `1a1de54f7369cd`).
* `CONFIG_EC_ASUS_GLYMUR=m`; the module is built natively:
  `drivers/platform/arm64/asus-glymur-ec.ko`, 465 648 B, and **ABI-verified against the running
  kernel**: vermagic identical (`7.3.0-rc3-next-20260914 SMP preempt mod_unload modversions aarch64`),
  `module_layout` CRC `0xe6658f7b` = the kernel's, and all **25 imports carry the kernel's CRC** (no
  missing, none disagreeing).
* The DTB builds from our tree with the EC node (`162 139 B`).
* `BRINGUP/tools/a16-ec.sh` (`sudo bash ~/a16.sh ec …`) does the rest — build, install, status,
  verify, revert.  Its DTB step adds the node to the **live, armed** DTB rather than replacing it with
  a tree build, because a tree build renumbers phandles and would have to re-apply the Bluetooth and
  tert-PHY changes; adding to the live one keeps them by construction (verified: 11 added lines, BT
  node / `w-disable2-gpios` polarity / `hdmi-bridge` power domain all still present).  The interrupt's
  phandle is read from the parent of the `ec-int-n-state` node and cross-checked against the
  `gpio-keys` node's own cells (`0x58` = TLMM), so the node cannot point at the wrong controller.

Nothing is installed yet: that step needs root.  Operator's line, once:

    sudo bash ~/a16.sh ec install        # module into updates/a16/ + both DTBs armed (backups .a16ecbak)
    sudo reboot                          # entry [3]
    bash ~/A16Build/BRINGUP/tools/a16-ec.sh verify

`verify` prints whether the driver bound, the fan/temperature readouts, the keyboard-backlight LED
and the EC's interrupts — and then points at `wifisleep test`, which is the test that matters.

## What to watch when it is installed

* `i2c-9` is present on this machine and has nothing at `0x76` today, so the client should appear at
  `/sys/bus/i2c/devices/9-0076` and the driver should bind without further work.
* If the driver binds but hwmon stays empty, the EC firmware may need the same "event enable" that the
  driver sends on probe; read the kernel lines in `verify` first.
* Keyboard backlight needs `CONFIG_LEDS_CLASS` (built in) and the LED name is `asus::kbd_backlight`.
* The interesting result is not a fan reading: it is whether `wifisleep test` still kills the radio.
  If the radio survives the first deep suspend with the EC driver bound, the EC was the missing half
  of the suspend path on this board, and the ladder in `wifisleep` (s2idle / reload hook) becomes the
  fallback rather than the plan.

## Installed and working (2026-09-22)

`sudo bash ~/a16.sh ec install` → restart → `a16-ec.sh verify`:

    DT node        : 1
    i2c client     : 9-0076
    driver bound   : asus-glymur-ec
    hwmon          : /sys/class/hwmon/hwmon21
       fan1_input = 1980   fan2_input = 1320   temp1_input = 33000   temp2_input = 36000
    kbd backlight  : asus::kbd_backlight        max_brightness = 3, brightness = 0
    EC interrupts  : 260:  5 ...  msmgpio  66 Edge  9-0076

Two things worth knowing:

* **The keyboard backlight is not missing — it is off.**  The LED appeared with the driver and its
  default brightness is 0 (`max_brightness = 3`).  Set it with `sudo bash ~/a16.sh ec kbd 2` (0–3);
  the driver sends `ASUS_EC_MBOX_CMD_KBD` and `verify` re-reads the value, so an EC that refuses the
  write is visible rather than silent.
* **The EC did not save the radio.**  A clean s2idle suspend with the EC driver bound still killed the
  Wi-Fi firmware (see `evidence/2026-09-22-ladder-runs.txt` §1 and §4), so the modern-standby
  notification is not what the Wi-Fi wedge was missing.  The EC stays for what it does give: fans,
  temperatures, backlight, and a channel for sideband events.

## v3 on hardware (2026-10-05)

v3 built into the `t2` tree, installed and booted. The driver binds and reports
fans, temperatures and the keyboard backlight, and both suspend and resume reach
the EC with `ret=0x0`:

    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-07]   STANDBY_CMD 0x23 / ENTER 0x07
    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-08]   STANDBY_CMD 0x23 / EXIT  0x08

    suspend_stats   success 3, fail 0, last_failed_dev empty
    s2idle          PM: suspend entry 08:10:04, exit 08:10:29, same boot

Machine, numbers and raw runs: `patches/asus-zenbook-a16-a14-ec-v3/`.

v3 is built in (`CONFIG_EC_ASUS_GLYMUR=y`), so there is no `.ko`, unlike the v1
build described above. The tree uses his Kconfig symbol rather than
`CONFIG_ASUS_GLYMUR_EC`.
