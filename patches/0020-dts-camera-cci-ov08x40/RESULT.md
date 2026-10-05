# 0020 — camera step 1: CCI + OV08X40 front sensor

What it is: the SoC's two CCI controllers, their pin groups, and the front camera's
OV08X40 node on CCI1 master 1.  It stops at I2C — no CAMSS, no CSIPHY, no CSI lane
enablement — so that a failure can only be the CCI or the sensor, never the ISP.

Only `cci1` is enabled.  `cci0` is defined and left `disabled`, exactly as the
upstream patch has it.

**This patch declares no regulators at all.**  The first revision declared the
camera's always-on rail and cost the machine its PCIe, wifi and USB-A; see "First
run" below.

## Where the content comes from

Three of Qualcomm's own patches, taken as posted, plus this machine's own values:

    glymur.dtsi  cci0/cci1 nodes, four cci pin groups   [PATCH 2/6] arm64: dts: qcom:
                                                        glymur: Add CCI definitions
                                                        (2026-09-07, glymur_camss v1)
    glymur.dtsi  cam_mclk0..4 pin groups                [PATCH 3/6] arm64: dts: qcom:
                                                        glymur: Add camera MCLK pinctrl
    board        sensor node shape, cci1_i2c1, reset    [PATCH 5/6] arm64: dts: qcom:
                 239, MCLK4 19.2 MHz, lanes 1-4,        glymur-crd: Add ov08x40 RGB
                 400 MHz                                sensor on CSIPHY4
    board        reset gpio 239, i2c address 0x36       CAMF_RES_MTP.bin (TLMMGPIO
                                                        0xEF), SCFG_FRONT_MTP.bin +
                                                        bus_info.primary.slave_config

The four pin combinations the patch relies on are all in the driver:
`cam_asc_mclk4` on gpio100, `cci_i2c_sda` on 101/103/105, `cci_i2c_scl` on
102/104/106, `asc_cci` on 235/236 (`drivers/pinctrl/qcom/pinctrl-glymur.c`).
The `asc_cci` pair is master 1 of cci1, which is where the reference board puts
this sensor.

## First run: what it did, and the one thing that hurt

Booted twice (two menu selections, 29 s each).  Both boots:

    CCI                    registered.  There is an i2c client at 0x36 on the cci1
                           master 1 adapter, and its probe reached the point of
                           asking for a supply:
                             i2c 21-0036: deferred probe pending: i2c: wait for
                             supplier /soc@0/rsc@18900000/regulators-0/bob1
                           So the address, the interrupt, the clock and the pinctrl
                           of cci1 are all right, and the sensor node was parsed.
    sensor                 deferred, never read its chip id -- the supply above did
                           not exist, because of the rail node described next.
    camera app             nothing, expected: step 1 registers no video device at
                           all.  A camera in the app needs CAMSS + CSIPHY4, which
                           is step 3.

The damage came from the rail node this revision had:

    vreg_bob1_b_e0: unsupportable voltage constraints 3416000-3384000uV
    qcom-rpmh-regulator ...:regulators-0: bob1: devm_regulator_register() failed, ret=-22
    qcom-rpmh-regulator ...:regulators-0: probe with driver qcom-rpmh-regulator failed with error -22
    (then) ...deferred probe pending: i2c: wait for supplier .../regulators-0/ldo15

`CAMF_RES_MTP.bin` votes BUCK_BOOST1_B_E0 at 3400000 uV, and PMH0101's BOB cannot
produce that value — its range is stepped, so the regulator core rejected the
constraints.  A failing child fails the container, and devres then unregistered
*every* rail of `regulators-0` with it: l8b/l15b (the wifi PCIe rails), the USB
rails, the rest.  Every consumer of PMH0101 deferred with them — no PCIe link, no
wifi (no ath12k), no USB-A (no xhci) — while the desktop came up normally, which is
exactly how it presented: "no camera and we lost wifi and USB".

Two lessons, both now in the patch:

* a rail node in a container whose other rails the board depends on is not a local
  change; the failure is not scoped to the rail;
* a vendor rail voltage is not automatically a legal constraint.  Check it against
  the driver's `REGULATOR_LINEAR_RANGE` before writing it.

So this revision declares no rails.  The sensor's `avdd`, `dovdd` and `dvdd` are
left undeclared, which makes the kernel hand out dummy regulators: they report
success and change nothing, so the probe still runs and the chip-id read is still
the result.  Nothing in this patch can now touch a rail the board depends on.

The rails move to step 2, together with patch 0021 and the module that can drive
the PMH0104 LDOs — a container that carries no board rails, so getting it wrong
stays local.  The `regulators-5` node from the first revision is gone from the patch
for the same reason.

## Verified before it is offered again

    patch applies to the tree          patch -p1 --dry-run, clean
    device tree compiles               make ARCH=arm64 dtbs, no dtc diagnostics
    cci1 registers                     0x0ac16000, interrupt 0x35b = 859, clocks
                                       CCI_1 (id 11) + CPAS AHB, pinctrl cci1_1
                                       default/sleep, status okay
    cci0 untouched                     present, status disabled
    sensor on cci1 master 1            camera@36 inside i2c-bus@1, reset -> tlmm
                                       0xef (239) ACTIVE_LOW, MCLK4 (id 0x45) at
                                       19200000, endpoint bus-type 4, clock-lanes
                                       0, data-lanes 1 2 3 4, link-freq 400 MHz
    no regulators anywhere             decompiled DTB has no supply property on the
                                       sensor and no bob1 under regulators-0

## Second run (boot b730f501, 2026-10-05 13:03): CCI half proven, sensor silent

Healthy boot first: wifi up (192.168.60.100, 14 ms), four USB-A devices enumerated, no
PCIe damage, and neither of the two failures above repeated.

    i2c-20, i2c-21     both named "Qualcomm-CCI"    cci1's two masters registered
    gpio235/236        "device ac16000.cci function asc_cci"   our pinctrl applied
    21-0036            name=ov08x40                 the sensor became an i2c client on
                                                    cci1 master 1 and its probe ran
    ov08x40 21-0036    supply dovdd / avdd / dvdd not found, using dummy regulator
    ov08x40 21-0036    error reading chip-id register: -6

-6 is -ENXIO: the transfer *completed* and the sensor did not ACK.  It is not a
timeout, so the CCI's completion interrupt, its clocks, the GDSC, the address
0xac16000 and the asc_cci pins on gpio235/236 are all proven, and the endpoint
parsed.  A sensor whose three supplies are dummy regulators does not ACK, which is
what this result looks like: the chip has no power control.  `/dev/video` is still
absent, by design — no CAMSS in step 1.

Step 1 did its job.  What stands between the tree and the chip id is power.

## Third run: the supplies are attached (not yet booted)

The three supplies now name the machine's own rails, in the PMH0104 container:

    avdd-supply  = <&vreg_l7i_e0>    PMH0104 I_E0 ldo7, 2.8 V
    dovdd-supply = <&vreg_l4i_e0>    PMH0104 I_E0 ldo4, 1.8 V
    dvdd-supply  = <&vreg_l4i_e0>    the same rail as dovdd

That mapping is not inferred: the vendor blobs vote LDO7_I0 (2800000 uV) and
LDO4_I0 (1800000 uV) for this sensor, and Qualcomm's own [PATCH 5/6] wires its
board's OV08X40 to one 2.8 V rail for avdd and one 1.8 V rail for dovdd and dvdd
-- the same shape, on the same three sensor pins.  Their reset pin (tlmm 239,
active low), pinctrl pair and 19.2 MHz MCLK4 match ours exactly.

The rails need the rebuilt regulator module (patch 0021), which is what step 2
installs; on the stock module this container still logs `ldo4: Unknown regulator`
and the sensor stays on dummy regulators.  The BOB stays out: the vendor votes it,
but nothing on this board needs a 3.4 V rail for the camera and its only legal
values are 3000000 + n*32000 uV.

Device tree re-verified after the change: one PMH0104 container, three supplies on
the sensor, cci1 and the endpoint unchanged, and the patch (now 398 lines)
reproduces the tree byte for byte from the pre-camera sources.

## Step 2: three shapes, and the one that is in use

**1. Hand-rolled unpack and repack -- panicked the machine.**  The installer unpacked
the initramfs with `cpio -i`, swapped the module and packed it again.  The camera entry
then panicked with "unable to mount root fs", and the numbers say why: 2645504 bytes
produced against the stock image's 48432086, 47 members, no `/init`.  A modern
initramfs is a sequence of archives -- this one is an uncompressed cpio followed by the
real tree as zstd -- and `cpio -i` stops at the first `TRAILER!!!`, so the rebuild kept
the early tree only.  The check that was meant to catch it compared "what I extracted"
against "what I repacked" and so could not see that the extraction itself stopped early.

**2. A fresh `mkinitramfs` build -- correct, but a different machine.**  Same generator,
same hooks, verified: 3928 members, `/init`, the module inside hashing to the staged
one.  But it selected 2584 modules against the stock image's 3090, and a difference of
506 modules on a boot path is not something to wave through.

**3. What is in use: the stock image plus one appended archive.**  The camera image is
the stock image's bytes, with one small archive appended that re-supplies only
`qcom-rpmh-regulator` at the path the stock image already keeps it at.  The kernel makes
that work: `unpack_to_rootfs` walks the segments in order and carries on after a
compressed one (`init/initramfs.c`, the loop around line 542), and `do_name` opens a
regular file with `O_TRUNC` and truncates it to the new body length (line 392), so the
later copy replaces the earlier one.  The appended archive is a single hand-built
record with no directory entries.

Failure mode: if a future kernel stopped honouring that rule, the camera entry would
boot the stock module -- no rails, no camera, no panic.  Nothing is installed into
`/lib/modules` at any point, no hook is left behind, and no other menu entry is touched.

Verified offline with the real image as a stand-in: the stock bytes are a byte-for-byte
prefix (`cmp -n`), the appended archive carries exactly the one path and adds no path
the stock image does not have, its copy hashes to the staged module
(6ae0320d42730c928042d791def70c8155aad8ba93a72993990c6293733f61f6), `/init` is present,
and a truncated tail is refused.

**Appending an archive after the stock image does not work.**  Implemented, installed,
booted: camera boot 06a14e9d's log still reads `regulators-5: Unknown regulator ldo4`
and `probe with driver qcom-rpmh-regulator failed with error -22` -- the stock module.
The appended archive was not used.  The shape in use therefore keeps everything before
the image's *last archive* byte for byte and rebuilds that one segment with the module
in place, which does not depend on the kernel reading past a compressed segment.

Validated offline on the real 48968838-byte image: the prefix is byte-identical, the
rebuilt segment's structural manifest and every regular file's hash match the stock
tree except the module, the module inside hashes to the staged one
(6ae0320d42730c928042d791def70c8155aad8ba93a72993990c6293733f61f6), and the member list
matches apart from the five `dev/*` nodes cpio cannot mknod as a non-root user.

Two tool traps found on the way, both worth keeping: `lsinitramfs`/`unmkinitramfs`
print nothing and exit 0 for an archive `mkinitramfs` writes here (so a check built on
them either refuses a good build or believes any archive), and `cpio -i --to-stdout`
exits 0 when the member is not in that archive.  The image is read by
`a16-camera-initrd-segments.py` plus GNU `cpio` instead.
