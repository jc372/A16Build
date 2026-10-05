# ASUS Zenbook A16/A14 EC driver — v3, Konrad Dybcio

    Series      [PATCH v3 0/3] Asus Zenbook A16/A14 (UX3607OA/UX3407NA) EC driver
    Author      Konrad Dybcio <konrad.dybcio@oss.qualcomm.com>
    Date        2026-09-23
    Message-Id  20260923-topic-asus_ec-v3-0-2bf3bb9da879@oss.qualcomm.com
    Thread      https://lore.kernel.org/all/20260923-topic-asus_ec-v3-0-2bf3bb9da879@oss.qualcomm.com/
    Cc          linux-arm-msm, devicetree, linux-hwmon, platform-driver-x86, linux-kernel

    1/3  dt-bindings: embedded-controller: Add ASUS Zenbook A16 EC
         Documentation/devicetree/bindings/embedded-controller/asus,zenbook-a16-ux3607oa-ec.yaml
    2/3  platform: arm64: Add a driver for the EC found on ASUS Glymur machines
         drivers/platform/arm64/asus-glymur-ec.c, Kconfig, Makefile
    3/3  arm64: dts: qcom: glymur-zenbook-a16: Add Embedded Controller
         arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dts

The driver provides, in its author's words: RPM of the two fans, temperature
readouts from two sensors, keyboard brightness get/set, and notification to the
EC of system suspend entry/exit.

## Tested on

    model        ASUS Zenbook A16 (UX3607OA)
    compatible   asus,zenbook-a16-ux3607oa / qcom,glymur
    soc          Qualcomm Snapdragon X2 Elite (Glymur)
    kernel       7.3.0-rc5-next-20261002-t2
    config       CONFIG_EC_ASUS_GLYMUR=y

    i2c 9-0076 -> driver asus-glymur-ec        i2c 9-005b, the EC subdevice
    hwmon4     name=asus_glymur_ec             led asus::kbd_backlight

All v3 hunks apply to this tree. Patch 3/3 needs no work here: the dts already
carries the identical node.

## Result

    fan1_input      1920-2040 RPM
    fan2_input      1320 RPM
    temp1_input     36-38 C    label CPU
    temp2_input     38-41 C    label SoC
    kbd_backlight   brightness 0, max 3

Suspend and resume both reach the EC:

    asus_glymur_ec_suspend   ret=0x0   488.593 us
    asus_glymur_ec_resume    ret=0x0   439.584 us

    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-07]
    i2c_write: i2c-9 #0 a=076 f=0000 l=2 [23-08]

    0x23   ASUS_QCOM_EC_MODERN_STANDBY_CMD
    0x07   ASUS_QCOM_EC_MODERN_STANDBY_ENTER
    0x08   ASUS_QCOM_EC_MODERN_STANDBY_EXIT

    pm_test=devices   suspend_stats success 2 -> 3, fail 0, last_failed_dev empty
    s2idle            PM: suspend entry 08:10:04, exit 08:10:29, same boot
                      suspend_stats success 1 -> 2, fail 0

Not tested: the lid switch, the power button, the sideband event mailbox
(`ASUS_EC_MBOX_CMD_MISC` 0x02 / `MISC_ENABLE` 0x83).

Numbers and raw runs: `evidence/FINAL-RESULT.txt`.

## Build, install, test

    cd ~/build/next-20261002-repull
    patch -p1 < patches/v3-combined.patch
    scripts/config --enable EC_ASUS_GLYMUR && make ARCH=arm64 olddefconfig
    make -j18 ARCH=arm64 Image modules dtbs

    sudo bash scripts/a16-install-ec-test.sh          # installs, keeps the boot default
    bash scripts/a16-install-ec-test.sh read          # the EC readings

    sudo bash scripts/a16-ec-suspend-test.sh probe    # suspend+resume callbacks, no power-down
    sudo bash scripts/a16-ec-suspend-test.sh real     # an actual s2idle cycle

`probe` sets `/sys/power/pm_test=devices`, so the kernel runs the full suspend
and resume callback path and returns without sleeping.

## Layout

    patches/      v1, v2 and v3 of the series as fetched, plus v3-combined.patch
    comparison/   which revision is which, by sha256
    evidence/     FINAL-RESULT.txt and the test runs
    port/         the tree's state after taking v3
    scripts/      the install and suspend-test scripts
