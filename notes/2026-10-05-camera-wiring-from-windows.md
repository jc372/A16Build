# Camera wiring, recovered from the machine's own Windows driver store

Where every number here comes from, so it can be re-derived or challenged:

    source   retired/firmware/windows-driverstore-2026-09-16/camera/
             and .../sensors/qcsensorsconfigcrd8480.inf_arm64_af945997cc98c4c3/
    plus     the DSDT of an A16 ACPI dump (another unit of the same model)

## Which sensor is the front camera

The `SCFG_FRONT_*.bin` files select the sensor config per board variant. Ours is
**MTP** (the product config), and it points at `Shinotech_ov08x` with an Ofilm lens:

    SCFG_FRONT_QRD.bin   (reference design)  com.qti.sensormodule.ov02c10.bin
    SCFG_FRONT_MTP.bin   (OUR board)         com.qti.sensormodule.Shinotech_ov08x.bin
    SCFG_FRONT_C2C.bin                       Shinotech_ov08x.bin

So: front camera = **OV08X** (8 MP, Shinotech module, Ofilm lens). Mainline's
`ov08x40` driver covers it and is already built. The OV02C10 in the same package is
the QRD/reference part -- not the front camera. Auxiliary sensor is a Himax HM1092.

## Power, clock, GPIO -- CAMF_RES_MTP.bin

This is the per-board power sequence for `\_SB.CAMF` (the front sensor device), read
from the named records inside the blob:

    rails      PMICVREGVOTE  BUCK_BOOST1_B_E0, LDO4_I0, LDO7_I0
               /arc/client/rail_mmcx
    MCLK       cam_cc_mclk4_clk                      <- MCLK4, 19.2 MHz
    clocks     gcc_camera_xo_clk, gcc_camera_ahb_clk, cam_cc_gdsc_clk, cam_cc_cpas_ahb_clk
    footswitch cam_cc_titan_top_gdsc
    GPIOs      TLMMGPIO 0xEF = 239      (reset / power enable)
               TLMMGPIO_V2 0x6A = 106   (second control line)
    delay      MTP 10 vs QRD 5 -- the only byte differing between the two configs

MTP and QRD share the wiring; they differ only in a delay. So this describes our
board, not just the reference design.

I2C address: `bus_info.primary.slave_config = 54`, annotated "right-shifted by 1,
w.r.t sensor xml" -> 54 << 1 = 0x6C -> **0x36** as the 7-bit address.

## SoC camera block map -- IRS1.bin / IRS2.bin

The ISP's own register files pair each name with an address:

    ICP        0x0AC00000     CSID_TOP    0x0ACB6000     IFE0      0x0AC62000
    RT_CDM_0   0x0AC25000     CSID0       0x0ACB7000     IFE1      0x0AC71000
    RT_CDM_1   0x0AC26000     CSID1       0x0ACB9000     IFELITE0  0x0ACC6000
    BPS        0x0AC2C000     IPE         0x0AC42000     IFELITE1  0x0ACCA000
                                                          0x0ACF9000, 0x0ACFA000

The camss node's base is the CSID wrapper, 0x0ACB6000 -- an earlier draft used
0x0ACB7000, which is CSID0, not the wrapper.

Front sensor sits on **csiphy4**: `C1PG.bin` clocks csiphy0/csiphy1/csiphy4, and the
earlier draft independently ended up at csiphy4.

## ACPI (DSDT), for the pieces the blobs do not carry

    CAMP (QCOM0F32, camera platform)   _DEP \_SB.PMIC.GIO0.PML0
      mem  0x0AC13000+0x1000, 0x0AC15000+0x1000, 0x0AC16000+0x1000, 0x0AC19000+0xC000
      irqs 488, 891, 252
      gpio TLMM 23, 25, 35, 99, 111
    MPCS (QCOM0F98, MIPI CSI)          mem 0x0ACE4000/0x0ACE6000/0x0ACEC000 +0x2000,
                                            0x0ACF6000/0x0ACF7000/0x0ACF8000 +0x400
      irqs 509, 510, 410
    JPGE (QCOM0F33)                    mem 0x0AC2A000+0x1000, 0x0AC2B000+0x1000, irq 295
    VFE0 (QCOM0F25)                    interrupts only, no memory
    Devices: CAMP, MPCS, VFE0, JPGE, FLSH, CAMF (front), CAMI (aux),
             AONC (always-on), SISP (secure ISP), CAMT, CAMU, CAMS

The DSDT has no `_CRS` for CAMF, and no CCI node at all -- the ISP driver hardcodes
the CCI. `CCI_` in the DSDT is the *UCSI* USB-C command-completion interrupt, a
red herring.

The camera platform's resource file enables `cam_cc_cci_0_clk` and `cam_cc_cci_1_clk`,
so the CCI lives inside the CAMP block -- i.e. one of those three 0x1000 regions.

## Still genuinely unknown

    CCI base + IRQ   one of 0x0AC13000 / 0x0AC15000 / 0x0AC16000,
                     irqs 488 / 891 / 252 -- to be found by probing, not guessing blindly
    rail mapping     which of BUCK_BOOST1_B / LDO4 / LDO7 is avdd vs dovdd vs dvdd
                     (dvdd 1.2V is almost certainly LDO4, an NLDO)
    buck-boost type  BUCK_BOOST1_B needs adding to qcom-rpmh-regulator for PMH0104
    CSI lanes/link   not needed to prove the sensor answers on I2C
    PMH0104 rails    pmh0104_i_e0 currently has no regulators node in the DT

## Why not just read the registers

The CCI address could be confirmed by reading candidate addresses, but these blocks
are clock-gated, and an access to an unpowered Qualcomm block can raise an SError and
panic the machine. A DT node is the safe route: the driver powers the block before
touching it.

## Test design

I2C only -- CCI + sensor node. No camss, no CSI lanes, no link frequency. Pass signal
is the driver's own chip ID check:

    OV08X40_REG_CHIP_ID 0x300a  expecting  0x560858

The t2 boot entry loads its own DTB (`/boot/glymur-a16-7.3.0-rc5-next-20261002-t2.dtb`),
separate from the default entry's (`/boot/glymur-asus-zenbook-a16-ux3607oa.dtb`), so a
bad camera DTB cannot affect a normal boot -- escape route is picking the usual entry.

# Update: Qualcomm posted the whole camera block, and it settles four of the unknowns

Everything above is the vendor-blob route.  There is a better source, and it was
sitting in the patchwork archive: Qualcomm's own glymur camera series, posted
2026-09-07 as `glymur_camss v1`, six patches.  Three of them are the device tree and
they answer what "Still genuinely unknown" above lists.  Message ids: 14795778
(CAMSS + CSIPHY nodes), 14795779 (CCI definitions), 14795780 (camera MCLK pinctrl),
14795781 (PM8010 camera PMIC), 14795782 (ov08x40 on CSIPHY4).  The series was
reworked for v2..v4 into driver + binding patches only, so the DTS half exists only
in v1 -- fetch it by patch id, not by searching for a later revision.  Copies are in
`~/a16-payload/camera/upstream/`.

What it settles:

    cci0                 0x0ac15000, GIC_SPI 456, CAM_CC_CCI_0_CLK
    cci1                 0x0ac16000, GIC_SPI 859, CAM_CC_CCI_1_CLK
    clock names          "ahb" (CPAS_AHB) and "cci" -- no camnoc_axi at all
    front sensor         cci1, master 1: cci1_i2c1, the asc_cci pins gpio235/236
    reset, MCLK, address tlmm 239 ACTIVE_LOW, CAM_CC_MCLK4_CLK at 19.2 MHz, 0x36
    endpoint             bus-type CSI2_DPHY, clock-lanes 0, data-lanes 1-4,
                         link-frequencies 400 MHz
    camss                isp@acb6000, compatible "qcom,glymur-camss" -- already in
                         this tree's driver, but there is no DTS node for it yet

## Corrections to the sections above

1. **The CCI interrupts were the ACPI numbers, not the GIC ones.**  The ACPI resource
   buffer for CAMP carries 488 / 891 / 252, and the GIC cell is that minus 32: 456
   and 859.  The -32 rule is not a guess -- the same buffer gives the geni I2C
   controllers, and 385 -> GIC_SPI 353 (i2c8 @0xa80000), 386 -> 354 (i2c9),
   395 -> 363 (uart14), 617 -> 585 (i2c20) all hold in this tree's DTS.
2. **The ACPI memory descriptors are not paired positionally with the interrupts.**
   In buffer order the regions are 0xac13000, 0xac19000+0xc000, 0xac15000, 0xac16000
   and the interrupts 488, 891, 252 -- but 0xac15000 is cci0 (488) and 0xac16000 is
   cci1 (891), so the 0xac19000 region (the CDM) is not what 891 belongs to.
   Anything built on in-order pairing would have been wrong.
3. **"I2C only, no link frequency" was wrong about the driver.**  ov08x40's probe
   parses the endpoint with `v4l2_fwnode_endpoint_alloc_parse()` and requires
   `link-frequencies`, before it touches the bus; without an endpoint it returns
   -EPROBE_DEFER, and without a bus-type the parse fails.  The step-1 node therefore
   carries bus-type, clock-lanes, data-lanes and link-frequencies, but no
   remote-endpoint, because CAMSS stays out of step 1.
4. **The running kernel's rpmh-regulator does know `qcom,pmh0104-rpmh-regulators`**
   (compatible matched in the module), but **it does not know PMH0104's LDOs**:
   the installed module's `pmh0104_vreg_data` symbol is 160 bytes = smps1..4 + the
   32-byte terminator.  So a rail node for I_E0 fails with `Unknown regulator ldo4`,
   and step 1 leaves the sensor's dovdd/dvdd undeclared (dummy regulators) rather
   than deferring the whole probe.  A string test for `vdd-l4` etc. proves nothing:
   other PMICs use those exact names.  `readelf -sW` on the module is the test that
   works.  Patch 0021 carries the three lines; it needs a module rebuild (step 2).
5. **The rail voltages are in the vendor blob after all.**  `CAMF_RES_MTP.bin`'s
   entries carry a u32 in microvolts right after each rail name:
   BUCK_BOOST1_B_E0 = 3400000, LDO4_I0 = 1800000, LDO7_I0 = 2800000.  The encoding is
   confirmed by the MCLK4 entry in the same file, which carries 19200000.  So avdd is
   PMH0101 bob1 (the only one of the three this kernel can drive), and dovdd/dvdd are
   the PMH0104 LDOs.
6. **`pmh0104-glymur.dtsi` already names the PMIC**: spmi_bus0 USID 0x8 is
   `pmh0104_i_e0`, which is where pmic-id `"I_E0"` comes from -- it is not an
   invention, and upstream's hawi/kaanapali boards use the same id for pmh0104.

## Where step 1 stands

Built, verified, staged, not yet run.  The device tree, the install script and the
collector are described in `~/a16-payload/camera/readme-camera-step1.md`; the change
is patch 0020 in the repo with its RESULT.md.  Pass signal: the log's verdict line
`sensor driver : BOUND (ov08x40)`, which means reset + 19.2 MHz clock + the always-on
rail were right and the chip answered its ID (0x560858) over cci1 master 1.

The next thing after that, in order: rebuild `qcom-rpmh-regulator` with 0021 so the
PMH0104 LDOs exist (then dovdd/dvdd can be wired to ldo4/ldo7 at 1.8/2.8 V), and only
then CAMSS + CSIPHY4, which is the rest of Qualcomm's v1 series and is already in the
driver.

# Step 1, first run: the CCI works, and one rail node cost wifi and USB-A

Two boots were taken (journal boots `-2` and `-1`, boot ids 95315f56 and 92653271, 29
seconds each).  Both are in the journal and the failure is unambiguous.

**What worked.**  The CCI registered: an i2c client sits at 0x36 on the cci1 master 1
adapter and its probe reached the supply lookup --

    i2c 21-0036: deferred probe pending: i2c: wait for supplier
                 /soc@0/rsc@18900000/regulators-0/bob1

-- so the address, the interrupt (859), the CCI_1 clock, the `cci1_1` pinctrl on
gpio235/236 and the endpoint parse are all right.  That is most of step 1, obtained
by accident, from the boot that went wrong.

**What broke it.**  The patch declared the camera's always-on rail, PMH0101 bob1 at
the vendor's 3400000 uV, inside `regulators-0` -- the container that holds the rails
the *board* depends on:

    vreg_bob1_b_e0: unsupportable voltage constraints 3416000-3384000uV
    regulators-0: bob1: devm_regulator_register() failed, ret=-22
    regulators-0: probe with driver qcom-rpmh-regulator failed with error -22
    ...deferred probe pending: i2c: wait for supplier .../regulators-0/ldo15

PMH0101's BOB range is stepped and 3400000 uV is not on the grid, so the constraint
was unsatisfiable.  A failing child fails its container, devres unregistered every
other rail of `regulators-0` with it (l8b/l15b = the wifi's PCIe rails, the USB
rails, the rest), and every consumer deferred: no PCIe link, no ath12k, no xhci.  The
desktop came up fine, because the display does not need PMH0101.  To the user: "no
camera and we lost wifi and USB".  Reboot into the usual entry and everything is
back, which is what boot 0 shows (wifi at 192.168.60.100, Keychron dongle enumerated).

**What changed because of it.**  0020 now declares no regulators at all; the sensor's
avdd/dovdd/dvdd are undeclared, so the kernel hands out dummy regulators and the
probe still runs.  The rails move to step 2, where the PMH0104 container is one this
board has no other consumers in -- a mistake there stays local.

**Two rules worth keeping**, both cheap to apply:

* a rail node is never a local change.  If it is in the same container as rails the
  board needs, a bad value takes all of them out, and the damage shows up as
  unrelated hardware (wifi, USB) going missing.
* a vendor rail voltage is not a legal constraint.  Check it against the driver's
  `REGULATOR_LINEAR_RANGE` (min, min_sel, max_sel, step) before writing it, or the
  probe fails with `unsupportable voltage constraints`.

Also worth knowing: the collector service is what leaves the evidence, and in a boot
that is rebooted after 29 seconds it never ran.  It now runs twice -- 10 s and 55 s
after sysinit -- so the first pass is on disk before anything that could hang.

**And the expectation to set with the user**: step 1 cannot put a camera in the app.
No CAMSS, no csiphy4, no /dev/video.  That is step 3, and it is the rest of the same
Qualcomm series.

# Step 1, second run (boot b730f501): the CCI half is proven

Healthy boot, no wifi/USB damage.  The collector log
(`patches/0020-.../evidence/2026-10-05-camera-boot-b730f501.log`) says:

    i2c-20, i2c-21    "Qualcomm-CCI"          cci1's two masters registered
    gpio235/236       device ac16000.cci, function asc_cci   our pinctrl applied
    21-0036           name=ov08x40             sensor is an i2c client on cci1 master 1
    ov08x40 21-0036   supply dovdd/avdd/dvdd not found, using dummy regulator
    ov08x40 21-0036   error reading chip-id register: -6

-6 = -ENXIO: transfer completed, no ACK.  Not a timeout, so the CCI's completion
interrupt, address, clocks, GDSC and the asc_cci pin mux all work, and the endpoint
parsed.  The chip does not ACK because its three rails are dummy regulators -- the
board's own PMH0104 LDOs are what it actually runs on, and this kernel cannot
describe them.  So: cci1 is right, and the missing piece is power, not the bus.

Next: step 2 = rebuild `qcom-rpmh-regulator` with 0021, then the rails in the
PMH0104 container (avdd ldo7 2.8 V, dovdd/dvdd ldo4 1.8 V), and the BOB only at a
value on its step grid.  Then CAMSS + CSIPHY4 for the app itself.

# Step 2 built (not yet booted)

- The module: `drivers/regulator` built in the same tree that produced the running
  kernel, with 0021 applied.  Safety rests on four facts: the tree's Module.symvers
  is the kernel's own (31165 symbols, `module_layout` 0x297b75c6, identical to the
  installed module), the new module's vermagic and `module_layout` CRC match it
  exactly, `pmh0104_vreg_data` is 256 bytes (7 rails + terminator, was 160), and the
  change is three static const table entries -- no code path.  The ABI gate could
  not run: this kernel has no `/sys/kernel/btf/vmlinux`, so it has no BTF to read
  offsets from.  Same-tree + same-CRC is the substitute, and it is checked in the
  installer.
- The install path: the module goes ONLY into a second initramfs
  (`/boot/initrd.img-<ver>-camera1`) that the camera entry boots.  It is not
  installed into `/lib/modules`, so a bad module cannot reach the usual boot paths
  -- that is what makes "I can always get back in" true here rather than hopeful.
  The installer refuses to install a repack that drops initramfs members, and it
  proves the module inside the new initramfs hashes to the staged one.
- The rail grid that caused the first failure, for the record:
  `pmic5_bob`: `REGULATOR_LINEAR_RANGE(3000000, 0, 31, 32000)` -- 3.000 V + n*32 mV.
  The vendor's 3400000 uV sits between two steps; 3392000 and 3424000 are legal.
- Still open: the third boot.  Pass = no dummy-regulator lines, `rpmh-regulator`
  registering ldo4/ldo7 for I_E0, and 21-0036 reading a chip id.

# Step 2, first attempt: kernel panic.  The initramfs is not one archive.

What happened: the camera entry panicked with "unable to mount root fs".  The cause
was mine and it is measured, not guessed -- the installer's hand-rolled rebuild
produced a **2645504 byte** initramfs against the stock one's **48432086 bytes**.

Why: a modern initramfs-tools image is a concatenation.  This machine's starts with
an uncompressed cpio holding a small early tree and continues with the real tree as
zstd (`COMPRESS=zstd` in /etc/initramfs-tools/initramfs.conf).  `file` reports the
first magic, so it looked like a plain cpio; `cpio -i` stops at the first `TRAILER!!!`
so the unpack got 47 members out of the whole image; the repack was therefore a
47-member fragment with no `/init` and none of the root filesystem's modules -- and
a kernel with no init in the initramfs and no driver for the root disk says exactly
"unable to mount root fs".

The check that was supposed to catch this compared "the members I extracted" against
"the members I repacked", so it could not see that the extraction itself had
stopped early.  A check phrased from the *stock* image's contents would have caught
it; that is what the new verification does, with `lsinitramfs` (which understands
the concatenated layout) comparing the stock member list against the new one, plus
`/init` by name, the module's hash inside the image, and the integrity of the stock
image itself.

Fix: the camera initramfs is now built by `mkinitramfs` -- the same generator, same
hooks (including `a16-qcom-firmware`, which the ADSP needs) -- with the rebuilt
module supplied two ways for one build (swapped into /lib/modules for the duration,
and a transient hook that overwrites it inside the image), then verified.  The stock
module is restored and the hook removed before anything else happens, and a trap
does the same if the run is interrupted.  On any failure the camera entry goes back
to the stock initramfs, so it cannot be left armed on an image that does not boot.

The escape route held: the usual entries boot the same tree, the same initramfs and
the same module they did before, which is why the machine came back with no
intervention.

# Two tool traps found while fixing that, worth keeping

1. **`lsinitramfs` and `unmkinitramfs` are silent liars here.**  For the 89 MB archive
   `mkinitramfs` wrote, both print *nothing at all* and exit 0 -- no error, no output
   -- while listing the stock image fine.  (`lsinitramfs` is a 58-line shell script
   that just runs `unmkinitramfs --list`, and `unmkinitramfs` is a 66 KB ELF.)  A
   verification based on them cannot tell "this archive is empty" from "I could not
   read this archive", so the image is now read directly:
   `a16-camera-initrd-segments.py` walks the headers (plain cpio to its TRAILER, skip
   the zeros, look at the next magic -- the kernel's own rule) to find where each
   segment starts, and GNU `cpio` lists each segment through `tail -c +<offset>`.
   The 89 MB build came out as `0 cpio` + `12871168 zstd`, 3928 members, and the
   module inside it hashed to the staged one.

# Step 2, final shape: the stock image plus one appended archive

Three shapes were tried, all of them mine.  Hand-rolled unpack/repack lost everything
after the first archive and panicked the machine.  A fresh `mkinitramfs` build worked
but chose its own module set -- 2584 modules against the stock image's 3090 -- which is
not a difference worth having on a boot path.  The third is: the stock image's bytes,
with one small archive appended that re-supplies only `qcom-rpmh-regulator`.

It works because of how the kernel reads an initramfs (`init/initramfs.c`):
`unpack_to_rootfs` walks the segments in order and carries on past a compressed one,
advancing by what the decompressor consumed, and `do_name` opens a regular file with
`O_TRUNC` and truncates it to the new body length, so a file a later archive provides
replaces the earlier copy.  Debian's own images rely on the same mechanism.  The
appended archive is a single hand-built record with no directory entries (a repeated
directory would have the kernel try to create a path that already exists, and the
parents are in the stock image anyway), carrying the name spelled exactly as the stock
image spells it.

So the failure mode is "nothing happened", not "cannot mount root": if a future kernel
ignored the appended archive, the camera entry would boot the stock module -- no rails,
no camera, no panic.

Checked offline against the real image used as a stand-in: the stock bytes are a
byte-for-byte prefix, the appended archive carries exactly the one path, it adds no
path the stock image does not have, its copy hashes to the staged module, `/init` is
present, and a truncated tail is refused.

2. **`cpio -i --to-stdout <member>` exits 0 when the member is not in that archive.**
   Extracting the module from the first segment therefore "succeeded" with empty
   output and the check reported a mismatch.  Extract into a file and test `-s`, not
   the exit status.
- The machine's initramfs is an **uncompressed SVR4 cpio** ("ASCII cpio archive",
  48432086 bytes), not zstd or gzip, which is what `file` reports for it.  Detecting
  the archive kind by magic bytes (`od -An -tx1 -N6`) rather than by `file`'s wording
  is what fixed the first install attempt: `file`'s phrasing differs between versions
  and a plain archive has no compression case at all if you only code for zstd/gzip/xz.
  The installer now handles none/gzip/xz/zstd as first-class kinds and keeps the
  archive kind it found.

