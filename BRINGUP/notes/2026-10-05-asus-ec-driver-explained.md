# The A16 EC driver — terms, and why the gaps are the gaps

2026-10-05. Companion to
`BRINGUP/patches/asus-zenbook-a16-a14-ec-v3/` — that directory holds the
maintainer-facing result and the patches. This file holds the background, so the
result file can stay short. For us, not for a maintainer.

## MAILBOX

"Mailbox" is the driver's own word, not ours. `ASUS_EC_PAGE_MAILBOX` 0xc4 is an
EC register page; it holds `ASUS_EC_MBOX_REG_CMD` 0x30, `SUBCMD` 0x31 and `DATA`
0x32, and the helpers are `asus_ec_wait_mailbox()` and `asus_ec_mailbox_cmd()`.
"MBOX" in the identifiers is just the author's abbreviation of it.

It is the EC's paged register window — the driver reaches the EC through
`asus_ec_readb(ec, page, reg, &out)` / `asus_ec_writeb(ec, page, reg, data)`.
It is **not** the kernel mailbox framework: no `<linux/mailbox.h>`, no
`mbox_chan`, no provider/consumer binding. "Mailbox" in a kernel context usually
means that framework, so if the author ever asks for comments on the driver, the
name is a fair thing to flag.

A command is submitted by writing SUBCMD, then DATA, then CMD, and polling CMD
until the EC clears it to zero — five tries, 5 ms apart. Page 0xc6 is the
temperature page, holding the CPU sensor at 0xa6 and the SoC at 0x2a.

## SUSPEND AND RESUME — why a clean suspend is evidence

`asus_glymur_ec_suspend` and `_resume` are `dev_pm_ops` callbacks, not runtime
PM. Each calls `asus_glymur_ec_modern_standby()`, which is a single
`i2c_smbus_write_byte_data()` to 0x76 with 0x23 as the command and 0x07 or 0x08
as the value — and it returns that result.

That return value is what makes the test checkable. The PM core aborts a suspend
whose device callback fails, so a cycle that completes cannot be hiding a failed
EC write. A clean suspend is therefore itself evidence, independent of whether
anything looked right on screen.

## WHY THE EVENT PATH IS THE ONLY GAP

`asus_ec_irq()` reads `ASUS_QCOM_EC_EVENT_CMD` 0x05 and logs the code with
`dev_dbg_ratelimited()` — hotkey, fan status, thermal trip, critical trip,
thermistor. Nothing prints at the default log level, so a normal boot gives no
way to tell whether the EC ever raises an event.

Covering it would need `CONFIG_DYNAMIC_DEBUG` plus `dyndbg="module
asus_glymur_ec +p"` on the kernel command line. That is more than a test report
needs, which is why it is declared untested rather than chased.

## WHY THE MAILBOX IS NOT IN THE "NOT TESTED" LIST

`asus_ec_enable_writes()` sends `MBOX_CMD_MISC` 0x02 / `SUBCMD_MISC_ENABLE` 0x83
during probe, and the probe aborts if it returns an error:

    ret = asus_ec_enable_writes(ec);
    if (ret < 0)
        return dev_err_probe(dev, ret, "Failed to enable EC direct access: %d\n", ret);

The driver binds, so that command succeeded. It is proven, not untested. The
keyboard backlight level goes through the same mailbox (`CMD_KBD` 0x01 /
`SUBCMD_KBD_LVL` 0x87), which is why setting the backlight is also evidence the
mailbox works.

## WHY THE LID SWITCH AND POWER BUTTON ARE NOT MENTIONED

An early draft of the result file listed them as untested. They are not this
driver: `asus-glymur-ec.c` contains no lid or power-button code at all, and the
board dts handles both through `gpio-keys`. Listing them would imply the series
covers them.

(The Kconfig help text we carried in our own port said "Provides the lid switch,
power button and thermal sensors" — that text was ours and it was wrong. It is
gone; the tree uses the author's Kconfig now.)

## WHY THE TREE DETAILS MATTER TO HIM

The board dts file that patch 3/3 touches also carries unrelated local patches of
ours — Bluetooth serdev and regulators, an RTC property, and the HDMI
power-domain workaround. None touch his `&i2c9` hunk, but a maintainer reading
our tree would see them, so the result file says so rather than letting them be
discovered.

## THE ONE THING WE CHANGED FROM HIS POSTED SERIES

Nothing in the patch. Verified byte-for-byte: driver 600 lines sha
`3aad31107d7278ad42b81afa`, binding 64 lines sha `c19ad1a643f8598e4416b991`, and
the `&i2c9` block his 3/3 produces is identical to ours.

Two differences worth knowing, neither of them an edit to his patch:

- Built in as `=y`, where his Kconfig allows `=m`.
- Our port's own `0002-dts-ec-node.patch` had already added the same EC node,
  which is why his 3/3 reported "already applied" when the series went in.
