# 0021 — regulator: qcom-rpmh: PMH0104 camera LDOs

Three lines in `pmh0104_vreg_data`: `ldo3`, `ldo4` and `ldo7`.  Without them the
PMH0104 container on this board has only `smps1..4`, so the camera rails cannot be
described in the device tree at all — `vreg_l4i_e0`/`vreg_l7i_e0` would have nothing
to bind to.

## The installed module does NOT have it

Measured, after a string test turned out to be worthless: `vdd-l3`, `vdd-l4` and
`vdd-l7` each appear as an exact string in the *unpatched* module too, because other
PMICs' tables use them as supply names, so `strings | grep -x` proves nothing.

What does prove it is the size of the table symbol:

    $ readelf -sW /lib/modules/7.3.0-rc5-next-20261002-t2/kernel/drivers/regulator/qcom-rpmh-regulator.ko \
        | grep pmh0104_vreg_data
    0000000000004630   160 OBJECT  LOCAL  DEFAULT   10 pmh0104_vreg_data

`struct rpmh_vreg_init_data` is 32 bytes on arm64, which the rest of this module
confirms (pmh0101 = 672 = 20 rails + terminator, pmh0110 = 480 = 14 + terminator).
160 bytes = 4 rails + terminator = `smps1..4`.  So the running kernel's PMH0104 has
no LDOs, and the PMH0104 container in the camera device tree cannot bind until a
module carrying this patch is installed.

## Why it is still in the applied set

The tree on this machine has lost the change, and a future `build.sh` run would
build a kernel without it — the same class of surprise as an out-of-date module, from
the other direction.  Keeping it in the set means patches 0001..0021 describe the
boards' rails completely, and step 2 has its source of truth in the repo.

## Status

Not applied to the tree, and no module rebuilt for it.  A module rebuild is subject
to the ABI rule (build only through `a16-build-gpucc-native.sh`, or after
`a16-abi-layout-gate.sh` passes), and it would touch a boot-critical module that the
daily entry shares, so it was deliberately left out of camera step 1.

    patch -p1 --dry-run        applies, hunk #1 at offset 3 lines
