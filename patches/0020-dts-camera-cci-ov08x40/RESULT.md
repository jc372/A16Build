# 0020 — camera step 1: CCI + OV08X40 front sensor

What it is: the SoC's two CCI controllers, their pin groups, the board's camera
rails, and the front camera's OV08X40 node on CCI1 master 1.  It stops at I2C — no
CAMSS, no CSIPHY, no CSI lane enablement — so that a failure can only be the CCI or
the sensor, never the ISP.

Only `cci1` is enabled.  `cci0` is defined and left `disabled`, exactly as the
upstream patch has it.

## Where the content comes from

Three of Qualcomm's own patches, taken as posted, plus this machine's own values:

    glymur.dtsi  cci0/cci1 nodes, four cci pin groups   [PATCH 2/6] arm64: dts: qcom:
                                                        glymur: Add CCI definitions
                                                        (2026-09-07, glymur_camss v1)
    glymur.dtsi  cam_mclk0..4 pin groups                [PATCH 3/6] arm64: dts: qcom:
                                                        glymur: Add camera MCLK pinctrl
    board        sensor node shape, cci1_i2c1, reset    [PATCH 5/6] arm64: dts: qcom:
                 239, MCLK4 19.2 MHz, lanes 1-4,        glymur-crd: Add ov08x40 RGB
                 400 MHz, bond to the 2.8 V rail        sensor on CSIPHY4
    board        reset gpio 239, i2c address 0x36       CAMF_RES_MTP.bin (TLMMGPIO
                                                        0xEF), SCFG_FRONT_MTP.bin +
                                                        bus_info.primary.slave_config
    board        rail voltages                          CAMF_RES_MTP.bin carries them
                                                        as u32 microvolts next to each
                                                        rail name

The four pin combinations the patch relies on are all in the driver:
`cam_asc_mclk4` on gpio100, `cci_i2c_sda` on 101/103/105, `cci_i2c_scl` on
102/104/106, `asc_cci` on 235/236 (`drivers/pinctrl/qcom/pinctrl-glymur.c`).
The `asc_cci` pair is master 1 of cci1, which is where the reference board puts
this sensor.

## The rails, and why only one of the three is wired

`CAMF_RES_MTP.bin` — the machine's own power sequence for this camera — votes three
rails, in order, with their voltages:

    BUCK_BOOST1_B_E0   3400000 uV    PMH0101 bob1 (pmic-id B_E0)
    LDO4_I0            1800000 uV    PMH0104 ldo4 (pmic-id I_E0)
    LDO7_I0            2800000 uV    PMH0104 ldo7 (pmic-id I_E0)

Only the first can be driven by the regulator driver this kernel runs.  The
installed `qcom-rpmh-regulator.ko`'s `pmh0104_vreg_data` symbol is 160 bytes, and
every entry in these tables is 32 bytes: that is four rails plus the terminator,
i.e. `smps1..4` and no LDOs — so a node under `I_E0` fails with `Unknown regulator
ldo4`, and anything bound to it defers forever.  The LDOs need patch 0021 compiled
into that module, which is step 2.

So the patch wires the sensor's `avdd` to bob1 at 3.4 V (the value and the rail the
vendor sequence gives it), and leaves `dovdd` and `dvdd` **undeclared** on purpose:
on a device-tree system the regulator core then hands out dummy regulators, which
report success and change nothing.  The sensor probe still runs, the CCI is still
exercised, and the result is judged on the chip id rather than on a deferred probe.

The PMH0104 container is still in the patch, commented, as the record of what the
board really has and what it cannot bind until step 2.

## Verified before it was offered as a test

    patch applies to the tree                    patch -p1 --dry-run, clean
    device tree compiles                         make ARCH=arm64 dtbs, no dtc diagnostics
    cci1 registers                              0x0ac16000, interrupt cell 0x35b = 859,
                                                 clocks CCI_1 (id 11) + CPAS AHB,
                                                 pinctrl cci1_1 default/sleep,
                                                 status okay
    cci0 untouched                               present, status disabled
    the sensor is on cci1 master 1               camera@36 inside i2c-bus@1, reset
                                                 phandle -> tlmm 0xef (239) ACTIVE_LOW,
                                                 clocks CAM_CC_MCLK4_CLK (id 0x45),
                                                 assigned rate 19200000,
                                                 endpoint bus-type 4, clock-lanes 0,
                                                 data-lanes 1 2 3 4, link-freq 400 MHz
    the rail is the one asked for                bob1 = 3400000 uV (0x33e140), mode AUTO,
                                                 and it is the only supply on the sensor

No module rebuild is needed for this step: the CCI driver, the OV08X40 driver, the
camcc clock driver and `qcom-rpmh-regulator` are all already built and installed.
Only the DTB changes.

## Test status

**Staged, not yet run.**  One boot is needed, into a menu entry that loads
`/boot/glymur-a16-camera1.dtb` with the t2 kernel:

    sudo bash ~/a16-payload/camera/a16-camera-step1.sh

The expected pass signal, and what each failure means, is in
`~/a16-payload/camera/readme-camera-step1.md`.  The evidence lands in
`~/a16-payload/camera/logs/boot-<boot-id>.log`.

Record the outcome here when it has been run: which of the log's verdict lines came
out, and the dmesg lines that produced them.  Expected and harmless in that log:
`supply dovdd not found, using dummy regulator`, `supply dvdd not found, using dummy
regulator`, and the two `Unknown regulator` lines from the PMH0104 container.
