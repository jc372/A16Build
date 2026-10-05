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

Read the install output.  These lines are the ones that matter:

    [ok]   vermagic matches the installed module
    [ok]   module_layout CRC matches
    [ok]   the module carries the PMH0104 LDOs (vreg table 256 bytes = 7 rails)
    [ok]   the stock initramfs is byte-identical to before the build
    [ok]   members: N, none of the stock's N missing
    [ok]   the new initramfs has its /init
    [ok]   all N copy/copies inside hash to the staged module
    [ok]   camera entry now boots initrd.img-<version>-camera1

Then reboot and pick the camera entry.  The run builds a second initramfs for the
camera entry with the rebuilt `qcom-rpmh-regulator` inside, using `mkinitramfs` and
the same hooks that built the initramfs the machine boots today, installs the device
tree that names the three supplies, and points the camera entry at that initramfs.
The module is not put into /lib/modules and no other menu entry is changed, so the
usual entries boot the same device tree, the same initramfs and the same module as
before.

Two things to know before you run it:

* every run leaves a log at `~/a16-payload/camera/logs/step2-<timestamp>.log`, so
  the output is still there afterwards if the terminal scrolls away;
* if any check fails, the camera entry is put back on the stock initramfs before the
  script exits, so it is never left pointing at an initramfs that cannot boot.

Why the archive is built with `mkinitramfs` rather than assembled by hand, and what
happened the one time it was: `patches/0020-dts-camera-cci-ov08x40/RESULT.md`.

Pass in `~/a16-payload/camera/logs/boot-<id>.log`: no `using dummy regulator` lines
for the sensor, `rpmh-regulator` registering ldo4 and ldo7, and the chip id read
answered.  The camera still does not appear in the app -- CAMSS and CSIPHY4 are
step 3.
