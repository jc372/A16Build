# ASUS Zenbook A16/A14 EC driver — Konrad Dybcio, v3

What this is: Konrad Dybcio's upstream EC driver, the evidence from testing it
on the A16, and what we did to our tree to test it.

    Series      [PATCH v3 0/3] Asus Zenbook A16/A14 (UX3607OA/UX3407NA) EC driver
    Author      Konrad Dybcio <konrad.dybcio@oss.qualcomm.com>
    Date        23 Sep 2026
    Message-Id  20260923-topic-asus_ec-v3-0-2bf3bb9da879@oss.qualcomm.com
    Thread      https://lore.kernel.org/all/20260923-topic-asus_ec-v3-0-2bf3bb9da879@oss.qualcomm.com/
    Cc          linux-arm-msm, devicetree, linux-hwmon, platform-driver-x86, linux-kernel

    1/3  dt-bindings: embedded-controller: Add ASUS Zenbook A16 EC
    2/3  platform: arm64: Add a driver for the EC found on ASUS Glymur machines
    3/3  arm64: dts: qcom: glymur-zenbook-a16: Add Embedded Controller

Earlier revisions: v1 (17 Sep), v2 (22 Sep), v3 (23 Sep). **v1 and v2 are
byte-identical** — v2 was a straight repost. v2 to v3 is the only substantive
change, and it is the review response: three added includes
(`container_of.h`, `dev_printk.h`, `lockdep.h`), braces on an `if`, and
`dev_info` demoted to `dev_dbg`.

## Why this machine matters

The cover letter says the Zenbook EC is

    bespoke embedded controller firmware, bearing some resemblence to the
    reference Qualcomm implementation (qcom-hamoa-ec.c), albeit with too many
    changes made to consider them anywhere near "compatible".

So Qualcomm's own reference boards cannot test it, and he says outright that
assuming A16/A14 compatibility "does not spark confidence". Someone holding the
exact model is the scarce input. As of 23 Sep the thread had no `Tested-by:`.

## What we did

Took his v3 into the t2 build tree (`~/build/next-20261002-repull`) and built it
in, replacing the v2 that our port had been carrying.

The port's own EC patches (`0002-dts-ec-node.patch`, `0004-ec-driver.patch`)
carried **his v2 verbatim** — not a fork. Only the Kconfig symbol name and help
text were ours (`CONFIG_ASUS_GLYMUR_EC` against his `CONFIG_EC_ASUS_GLYMUR`),
which had to go because a duplicate Makefile line adding the same object caused
confusing double-compilation. See `comparison/hashes.txt`.

Our dts patch 3/3 needed no work: our `0002-dts-ec-node.patch` already adds the
identical node, so the hunk reported "reversed or previously applied".

## Result — proven on hardware

The driver binds and the EC works:

    hwmon4  asus_glymur_ec      i2c 9-0076 -> asus-glymur-ec
    fan1 1920 RPM   fan2 1320 RPM   temp1 36.0 C (CPU)   temp2 38.0 C (SoC)
    kbd backlight  0 of 3, /sys/class/leds/asus::kbd_backlight
    i2c 9-005b present (the EC subdevice)

Suspend/resume notification — **captured on the wire, not judged by eye**:

    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-07]
                       bus i2c-9, addr 0x76 = the EC
                       bytes 0x23=STANDBY_CMD, 0x07=ENTER

    ...issued from inside asus_glymur_ec_suspend() in the ftrace call graph.

    0x23  ASUS_QCOM_EC_MODERN_STANDBY_CMD
    0x07  ASUS_QCOM_EC_MODERN_STANDBY_ENTER
    0x08  ASUS_QCOM_EC_MODERN_STANDBY_EXIT

    suspend_stats   success 2, fail 0, last_failed_dev empty
    journal         PM: suspend entry (s2idle) 08:10:04 -> suspend exit 08:10:29
    boot time       unchanged (08:04:47) — it resumed, it did not reboot

**Both halves captured**, with return values, from the safe `pm_test=devices`
stage (which runs the whole suspend and resume callback path without powering
down):

    asus_glymur_ec_suspend() { ... } /* asus_glymur_ec_suspend ret=0x0 */  488.593 us
    asus_glymur_ec_resume()  { ... } /* asus_glymur_ec_resume  ret=0x0 */  439.584 us

    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-07]   STANDBY_CMD / ENTER
    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-08]   STANDBY_CMD / EXIT

    suspend_stats 2 -> 3, fail 0, last_failed_dev empty

An earlier pass lost these to a 60-line cap in the first version of the test
script. The current script enables `funcgraph-retval` and greps every write to
address 0x76; `evidence/a16-ec-suspend-20261005-081553.log` has the full run and
`.log.trace` the whole trace buffer.

Everything the cover letter claims is therefore confirmed on this hardware:
fan RPM for both fans, two temperature sensors, the keyboard backlight, and the
suspend entry/exit notification — the last of these with the exact register, the
exact value, and the callback's own return value.

## Reproducing

    # build with his v3 in
    cd ~/build/next-20261002-repull
    patch -p1 < ~/a16-payload/asus-zenbook-a16-a14-ec-v3/patches/v3-combined.patch
    scripts/config --enable EC_ASUS_GLYMUR && make ARCH=arm64 olddefconfig
    make -j18 ARCH=arm64 Image modules dtbs

    # install (replaces /boot/vmlinuz-t2, keeps the boot default)
    sudo bash ~/a16-payload/a16-install-ec-test.sh
    bash ~/a16-payload/a16-install-ec-test.sh read

    # prove suspend/resume notification
    sudo bash ~/a16-payload/a16-ec-suspend-test.sh probe   # no power-down, zero risk
    sudo bash ~/a16-payload/a16-ec-suspend-test.sh real    # a real s2idle cycle

## Layout

    patches/      his mails as fetched from lore, plus the combined body
    comparison/   which revision is which, by sha256
    evidence/     the suspend/resume runs, logs and traces
    port/         the tree's state after taking v3, and what was replaced

## Notes for the reply

`To:` him, `Cc:` the lists he copied, `In-Reply-To:` the Message-Id above.
Plain text, bottom-posted. A direct mail is fine but a `Tested-by:` only counts
in the thread, because it has to go into the commit message and the maintainers
have to see it.

Everything in the cover letter is now confirmed on this machine, so the whole
claim is available: fan RPM for both fans, both temperature sensors, the
keyboard backlight, and suspend entry/exit being reported to the EC — the last
with the register, the values, and the callbacks' return values.

Worth including the awkward detail rather than hiding it: our port had been
carrying v2 verbatim, and the first test pass lost the return values to a
script bug of ours. Neither weakens the result, and both are the kind of thing
a maintainer would rather hear from the tester than discover later.
