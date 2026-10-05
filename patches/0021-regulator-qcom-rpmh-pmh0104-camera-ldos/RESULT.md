# 0021 — regulator: qcom-rpmh: PMH0104 camera LDOs

Three lines in `pmh0104_vreg_data`: `ldo3`, `ldo4` and `ldo7`.  Without them the
PMH0104 container on this board has only `smps1..4`, so the camera's rails cannot be
described in the device tree at all — `vreg_l4i_e0`/`vreg_l7i_e0` would have nothing
to bind to.

    static const struct rpmh_vreg_init_data pmh0104_vreg_data[] = {
        RPMH_VREG("smps1",   SMPS, 1,    &pmic5_ftsmps530, "vdd-s1"),
        ... smps2, smps3, smps4 ...
        RPMH_VREG("ldo3",    LDO,  3,    &pmic5_nldo530,   "vdd-l3"),
        RPMH_VREG("ldo4",    LDO,  4,    &pmic5_nldo530,   "vdd-l4"),
        RPMH_VREG("ldo7",    LDO,  7,    &pmic5_pldo530_mvp150, "vdd-l7"),
        {}
    };

`ldo4` and `ldo7` are the two the front camera's avdd/dovdd/dvdd hang off.  `ldo3` is
in the table because the PMIC has it, not because anything uses it.

## The stock module does NOT have it

Measured, after a string test turned out to be worthless: `vdd-l3`, `vdd-l4` and
`vdd-l7` each appear as an exact string in the *unpatched* module too, because other
PMICs' tables use them as supply names, so `strings | grep -x` proves nothing.

What does prove it is the size of the table symbol:

    $ readelf -sW /lib/modules/7.3.0-rc5-next-20261002-t2/kernel/drivers/regulator/qcom-rpmh-regulator.ko \
        | grep pmh0104_vreg_data
    0000000000004630   160 OBJECT  LOCAL  DEFAULT   10 pmh0104_vreg_data

`struct rpmh_vreg_init_data` is 32 bytes on arm64, which the rest of this module
confirms (pmh0101 = 672 = 20 rails + terminator, pmh0110 = 480 = 14 + terminator).
160 bytes = 4 rails + terminator = `smps1..4`.

That is what boot b730f501 showed from the other side:

    rpmh-regulator ... ldo4: Unknown regulator ldo4        <- once per rail
    ov08x40 21-0036: supply dovdd not found, using dummy regulator
    ov08x40 21-0036: error reading chip-id register: -6

The device tree had named the rails correctly — the container binds, the LDO
children parse — and the driver had nowhere to put them.  The sensor then ran on
dummy regulators, its three supplies stayed unpowered, and the chip did not ACK on
the bus.  -6 is -ENXIO: the CCI completed the transfer, the sensor simply was not
listening.

## How the module was built and what was checked

Built in `/home/jc/build/next-20261002-repull` — the tree that produced the running
kernel — with 0021 applied (`a16-build-rpmh-regulator-module.sh`):

    make ARCH=arm64 -j$(nproc) M=drivers/regulator modules KBUILD_MODPOST_WARN=1

    vermagic          7.3.0-rc5-next-20261002-t2 SMP preempt mod_unload modversions aarch64
                      (identical to the installed module)
    module_layout CRC 0x297b75c6   (identical to the installed module)
    pmh0104_vreg_data 256 bytes    = 7 rails + terminator (was 160)
    srcversion        C6482A562CE18DBB67E332B   (installed: 21D8A2500626FE56256A469)
    sha256            6ae0320d42730c928042d791def70c8155aad8ba93a72993990c6293733f61f6

The tree's `Module.symvers` is the one its own full build produced — 31165 symbols
with CRCs, `module_layout` 0x297b75c6 — so every symbol version in the module is the
running kernel's own, not a harvested guess.

**The ABI gate could not run.**  `a16-abi-layout-gate.sh` reads struct offsets from
`/sys/kernel/btf/vmlinux`, and this kernel has no BTF (`CONFIG_DEBUG_INFO_BTF` off;
the file does not exist).  What stands in its place, and is checked again by the step
2 installer before anything is installed: the module comes from the tree that built
the running kernel, from the same config, and its vermagic and `module_layout` CRC
match the installed module byte for byte; the kernel applies the same per-symbol CRC
check itself and refuses the module if any of them differs.  The change is three
static const table entries with no code path — there is no new branch for a
malformed entry to fall into.

## How it gets onto the machine

`a16-camera-step2.sh` builds a second initramfs for the camera entry with this module
inside and points that entry at it.  The module is deliberately **not** installed
into `/lib/modules`: the usual menu entries keep the initramfs, the module and the
device tree they boot today, so a mistake here cannot reach the stock kernel, and
`--remove` puts the camera entry back on the stock initramfs.

## Still in the applied set

The tree on this machine has lost the change in the past, and a future `build.sh` run
would build a kernel without it — the same class of surprise as an out-of-date
module, from the other direction.  Keeping it in the set means patches 0001..0021
describe the boards' rails completely, and step 2 has its source of truth in the
repo.

    patch -p1 --dry-run        applies, hunk #1 at offset 3 lines
