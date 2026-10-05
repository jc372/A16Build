# 0004-ec-driver

Konrad Dybcio's patch **2/3** of the same series, verbatim. Touches three files:
`drivers/platform/arm64/Kconfig`, its `Makefile`, and the new
`drivers/platform/arm64/asus-glymur-ec.c` (600 lines).

This replaces the version we had been carrying. Ours was his **v2** with the Kconfig
symbol renamed, and it was no longer what the machine ran — the running kernel has his
v3, so the patch set could not reproduce the kernel it was supposed to describe.

## Result

Runs the EC on this machine. Measured:

    binds            i2c 9-0076 -> asus-glymur-ec
    hwmon4           fan1 1920-2040 RPM, fan2 1320 RPM
                     temp1 36-38 C (CPU), temp2 38-41 C (SoC)
    backlight        1 of 3, and it responds
    suspend          asus_glymur_ec_suspend  ret=0x0   488.593 us
    resume           asus_glymur_ec_resume   ret=0x0   439.584 us
    on the wire      i2c-9 addr 0x76  [23-07] enter, [23-08] exit
                     (ASUS_QCOM_EC_MODERN_STANDBY_CMD / _ENTER / _EXIT)

The event path is the one thing not exercised — `asus_ec_irq()` reads
`ASUS_QCOM_EC_EVENT_CMD 0x05` and logs at `dev_dbg` only.

## Evidence

`../asus-zenbook-a16-a14-ec-v3/evidence/FINAL-RESULT.txt`
`../asus-zenbook-a16-a14-ec-v3/REFERENCE.md` — what the terms mean and why the gaps are the gaps.
