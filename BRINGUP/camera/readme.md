# Camera step 1: prove the CCI and the front sensor

What this is: a second boot entry that loads a device tree with the camera's CCI and
the front OV08X40 sensor in it, and a collector that writes down what happened.
The desktop is untouched, the usual entries are untouched, and step 1 stops at I2C:
no CAMSS, no CSIPHY, no CSI lanes.

**The camera app will still not see a camera in this step, and that is the design.**
A /dev/video device needs CAMSS + CSIPHY4 (step 3).  Step 1 answers one question:
does the sensor answer at 0x36 on the CCI, and are the CCI's address, interrupt,
clock and pins right.

**No regulator is declared, after the first attempt cost the machine its wifi and
USB-A** (a rail node whose voltage was not on the rail's step grid took the whole
PMH0101 container down, and every consumer deferred).  The sensor's three supplies
come from dummy regulators here, whatever the bootloader left.  The rails are step 2.

## Run it

    sudo bash ~/a16-payload/camera/a16-camera-step1.sh

Then reboot and pick, in the boot menu:

    A16: camera step 1 (CCI1 + OV08X40 sensor, t2 kernel)

Nothing has to be typed after that boot: the evidence is written to

    /home/jc/a16-payload/camera/logs/boot-<boot-id>.log

from inside that boot, by a oneshot service, whether or not the desktop comes up.

## What "it worked" looks like

Read the "--- what this boot shows" section at the end of the log:

    CCI i2c adapters : 2 (expect 2: the two masters of cci1)
    sensor client    : present at 0x36
    sensor driver    : BOUND (ov08x40)  <-- the sensor answered on I2C

`BOUND` is the pass. It means the sensor's reset, 19.2 MHz clock and rails were
right and the chip returned its ID (0x560858) over CCI1 master 1.

## What each failure means

| in the log | means | next |
| --- | --- | --- |
| `unsupportable voltage constraints` / any `regulators-N: probe ... failed` | a rail node's voltage is not on that rail's step grid, and the whole PMIC container went with it (this is what broke wifi + USB-A the first time) | take the rail node out; nothing in step 1 needs one |
| `cci@ac16000` present but no `Qualcomm-CCI` adapter | the CCI did not probe: read its dmesg line (`failed to get clocks`, `request_irq`, clock names) | that line names the missing piece |
| adapters up, `camera@36` absent, `parsing endpoint failed` | the sensor node parsed badly, not the sensor | a device tree fix, no reboot needed to diagnose |
| adapters up, no client at 0x36, i2c timeouts in dmesg | the sensor did not answer: reset, clock, rails or the master number | the rail set is the first thing to vary |
| machine hangs early in boot | do not wait: power-cycle and take the usual entry | the CCI address or its clock is wrong; the log stops where it stopped |

Lines that are expected in the log and mean nothing bad:

    supply avdd not found, using dummy regulator
    supply dovdd not found, using dummy regulator
    supply dvdd not found, using dummy regulator

Those are the sensor's three rails, undecided on purpose: this kernel cannot drive
the two the machine really uses (PMH0104 LDOs) and driving the third one wrongly is
what broke wifi and USB-A.  All three are step 2, and the probe runs regardless.

## Undo

    sudo bash ~/a16-payload/camera/a16-camera-step1.sh remove

That removes the menu entry from every menu that has it, the DTB, the collector and
its service, and leaves the backups next to the menus it edited.

## Files

    a16-camera-step1.sh            install / --check / remove
    a16-camera-report.sh           the collector (also runnable by hand)
    a16-camera-dts-edit.py         how the device tree was edited, in one file
    glymur-a16-camera1.dtb         the device tree this entry loads
    patches-out/camera-step1.patch the change as a patch against the build tree
    logs/boot-<boot-id>.log        what each boot of it produced

## Where each number in the device tree comes from

    cci1 base 0x0ac16000, SPI 859, CCI_1_CLK   Qualcomm's [PATCH 2/6] "glymur: Add CCI
                                              definitions" (2026-09-07, glymur_camss v1)
    sensor on cci1 master 1, reset tlmm 239,  Qualcomm's [PATCH 5/6] "glymur-crd: Add
    MCLK4 19.2 MHz, 0x36, lanes 1-4           ov08x40 RGB sensor on CSIPHY4"
    reset 239, MCLK4, address 0x36            this machine's own CAMF_RES_MTP.bin and
                                              SCFG_FRONT_MTP.bin (the vendor blobs)
    avdd -> PMH0104 (I_E0) ldo7, 2.8 V        CAMF_RES_MTP.bin votes LDO7_I0 at
                                              2800000 uV; upstream's [PATCH 5/6] puts
                                              avdd on its own 2.8 V rail the same way
    dovdd, dvdd -> PMH0104 ldo4, 1.8 V        CAMF_RES_MTP.bin votes LDO4_I0 at
                                              1800000 uV, and [PATCH 5/6] ties dovdd
                                              and dvdd to one 1.8 V rail.  These two
                                              need the rebuilt regulator module
                                              (step 2, patch 0021); on the stock module
                                              the kernel hands out dummy regulators
    pin numbers and functions                 drivers/pinctrl/qcom/pinctrl-glymur.c

## Step 2: the rails

    sudo bash ~/a16-payload/camera/a16-camera-step2.sh            # install
    sudo bash ~/a16-payload/camera/a16-camera-step2.sh --check    # verify, change nothing
    sudo bash ~/a16-payload/camera/a16-camera-step2.sh --remove   # undo

The run gives the camera entry its own initramfs: everything before the image's last
archive is kept byte for byte, and that last archive is unpacked, given the rebuilt
`qcom-rpmh-regulator` in place of the stock one, and packed again.  So the module the
kernel loads is the one with the PMH0104 rails, and every other file in the image is
the one the machine boots today.  Nothing is installed into `/lib/modules`, no hook is
left behind, and no other menu entry is touched.

(An earlier attempt appended the module as an extra archive after the stock image.
Measured on 2026-10-05, that does not work: the kernel went on using the stock module,
`regulators-5: Unknown regulator ldo4` in the log.  Hence replacing it inside the last
archive.)

Read the install output.  These lines are the ones that matter:

    [ok]   the stock initramfs is untouched
    [ok]   the first <offset> bytes are the stock image's, byte for byte
    [ok]   the rebuilt segment is the stock tree, differing only in the module
    [ok]   the module in the rebuilt segment is the staged one (6ae0320d...)
    [ok]   same <n> members as the stock image
    [ok]   /init is there
    [ok]   camera entry now boots initrd.img-<version>-camera1

Then reboot and pick the camera entry.  Every run leaves a log at
`~/a16-payload/camera/logs/step2-<timestamp>.log`; if any check fails the camera entry
is put back on the stock initramfs before the script exits, so it is never left armed
on an image that cannot boot.  And if a future kernel stopped honouring the appended
archive, the camera entry would simply behave like the stock boot -- no rails, no
camera, no panic.

Pass in `~/a16-payload/camera/logs/boot-<id>.log`: no `using dummy regulator` lines for
the sensor, `rpmh-regulator` registering ldo4 and ldo7, and the chip id read answered.
The camera still does not appear in the app -- CAMSS and CSIPHY4 are step 3.
