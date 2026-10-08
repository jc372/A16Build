# CPU DVFS: the CPUCP ("PDP0") firmware does not implement the SCMI perf protocol (2026-10-07)

Symptom: no `/sys/devices/system/cpu/cpufreq` at all — the CPUs never scale, there is no boost and no
cpufreq cooling device, so the machine cannot clock down at idle (bottom sits ~35-38 C doing nothing) and
cannot thermal-throttle under load.

## What actually happens at boot (verbatim)

    arm-scmi arm-scmi.0.auto: SCMI Protocol v2.0 'Qualcomm:PDP0' Firmware version 0x0
    arm-scmi arm-scmi.0.auto: timed out in resp(caller: do_xfer+0x158/0x780)
    arm-scmi arm-scmi.0.auto: Failed to query supported version for protocol 0x13.
    arm-scmi arm-scmi.0.auto: Trying version 0x40000. Backward compatibility is NOT assured.
    arm-scmi arm-scmi.0.auto: timed out in resp(caller: do_xfer+0x158/0x780)
    scmi-cpufreq scmi_dev.4: probe with driver scmi-cpufreq failed with error -110
    scmi-perf-domain scmi_dev.3: probe with driver scmi-perf-domain failed with error -110

So: the SCMI *channel* is healthy — the base protocol answers, the transport identifies itself as
`Qualcomm:PDP0` — but **protocol 0x13 (PERF) never answers at all**. Every request times out (-110/ETIMEDOUT)
and the performance-domain and cpufreq drivers fail to probe. The firmware reports implementation
`version 0x0`, i.e. unset: a minimal build that was compiled without the perf protocol.

## Why there is no fallback in the kernel or the DT

- Transport is correct and in use: `scmi { mboxes = <&pdp0_mbox 0>, <&pdp0_mbox 1>;
  shmem = <&cpu_scp_lpri1>, <&cpu_scp_lpri0>; protocol@13 { reg = <0x13>; } }`, with `pdp0_mbox` =
  `mailbox@17610000` = `qcom,glymur-cpucp-mbox`, `qcom,x1e80100-cpucp-mbox` — the **CPUCP** mailbox, shmem in
  `scp-sram-section@0/@180`. Base protocol works over it, so the channel is not the problem.
- The CPU nodes ask for DVFS exactly this way: `power-domains = <&cpu_pdN>, <&scmi_perf N>;
  power-domain-names = "psci", "perf";` — three perf domains (clusters).
- There is **no EPSS/OSM node** for glymur. Other Qualcomm SoCs in the same tree drive the CPU DVFS hardware
  directly (`qcom,freq-domain = <&cpufreq_hw N>`, `qcom,cpufreq-epss`) — agatti, eliza, kodiak, lemans, milos,
  monaco, qdu1000, sar2130p — but glymur/X1E does not declare that block, so `qcom-cpufreq-hw` has nothing to
  bind to. SCMI perf is the only path the platform describes.
- Driver availability is not the issue: `CONFIG_ARM_SCMI_CPUFREQ=m`, `CONFIG_ARM_QCOM_CPUFREQ_HW=m`,
  `CONFIG_CPUFREQ_DT=y` — all built; they simply have no working provider.

## The vendor's own ACPI does not do CPU DVFS either

The harvested tables (`/boot/efi/a16-harvest-20260728-124912.tar.gz`, extracted to scratch) contain the
DSDT (523 KB) and friends, and the DSDT has **no `_PSS`, `_PCT`, `_CPC`, `_CST` or `_PPC`** anywhere. The only
CPU-performance-ish string in any table is a bare `frequency`. So Windows is not using ACPI performance states
either — it uses a Qualcomm driver against the same firmware/hardware — and nothing in the tables names an
OSM/EPSS/DVFS block that could be described in DT. (The DSDT does carry ~130 `QCOMxxxx` device names = the
SoC block IDs; finding the CPU-perf one means decompiling with `iasl` and reading `_CRS` bases.)

## Where the firmware comes from

Nothing on the ESP matches `*pdp*`, `*cpucp*`, `*aop*` or `*.mbn` (`/boot/efi/` holds only Boot/, Microsoft/,
ubuntu/, ubuntu_snapdragon/, the loader/ dir and the harvest). So the CPUCP image is part of the **platform
UEFI/BIOS**:

    bios_version = UX3607OA.312      bios_date = 07/12/2026      board = UX3607OA (ASUS Zenbook A16)

## Conclusion and routes

1. **The fix is a platform firmware matter, not a kernel one.** Upstream's own glymur DT declares protocol@13,
   so some firmware build for this platform implements it; ours does not. Action: check whether ASUS has a
   BIOS release newer than `UX3607OA.312` (2026-07-12) and whether its release notes mention CPU
   performance/DVFS. If the CPUCP image changes, SCMI perf may simply start working.
2. **If the BIOS is already current**, the only in-Linux route is a direct hardware driver for the CPU DVFS
   block (an EPSS-style node + `qcom-cpufreq-hw`, or a new small driver). That needs the block's register base,
   which is not exposed anywhere obvious — the lead is the DSDT's `QCOMxxxx` devices and their `_CRS`
   resources, i.e. decompile with `acpica-tools` (`iasl -d`) and match a device whose resource window looks
   like a perf-state block. Treat as a real project, and treat any write to a power-management block as
   capable of hanging the machine: stage it, one variable at a time.
3. Consequence while it stays as-is: no frequency scaling, no boost, no CPU thermal throttling (the EC fans do
   that work; the thermal zones have no cooling device). Idle heat is the price, and 35-38 C at idle is
   harmless even though the chassis feels warm.

## How to re-test after any firmware change

    journalctl -k | grep -E "arm-scmi.*(protocol 0x13|PDP0|timed out)"
    ls /sys/devices/system/cpu/cpufreq            # exists = DVFS is working
    grep . /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies 2>/dev/null
