# Suspend power: what the overnight sleep actually cost

Measured on 2026-10-03/04, kernel `7.3.0-rc5-next-20261002-ec1`, pack `energy_full = 66.6 Wh`.

## The number

| | |
|---|---|
| Lid shut, one sleep | 23:34:06 -> 08:01:14 = **8 h 27 min** really asleep |
| Journal entries during the sleep | **1** (nothing woke it; no wake storm, no re-entry cycles) |
| Drain | **~20 Wh = 30 % of the pack** |
| Rate while asleep | **~2.4 W** |
| Rate while awake and idle | 9.3 W (desktop running) |

The sleep itself is sound: the gap between `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC` grew by
38,054 s across the night, so the machine truly froze. This is not a wakeup-storm problem.

## What it was NOT

Measured, not assumed:

| Suspect | Verdict |
|---|---|
| Wi-Fi (ath12k) left up | **No.** `23:34:05 wlP4p1s0: deauthenticating ... (Reason: 3=DEAUTH_LEAVING)`, re-auth + new DHCP lease at 08:01:25 |
| The four WSA8845 amps + SoundWire masters + ADSP | **No.** Powering the audio path down via its own routing switch moved the draw 9.31 W -> 9.26 W: **0.05 W** (0.4 Wh over 8 h) |
| Fans | **No.** `fan1_input 0`, `fan2_input 0`, 33-38 C |
| The `session.suspend-timeout-seconds = 0` in the WirePlumber rule | **Not the cause.** Amps stay `active` regardless; they are released by the routing switch, not by the sound server |

## What it is

`qcom-pcie` fails to put the links into the PCIe low-power state, logged at **every** resume:

```
qcom-pcie 1bf0000.pcie: Timeout waiting for L2 entry! LTSSM: 0x11
qcom-pcie 1bf0000.pcie: PCIe Gen.3 x1 link up        <- Wi-Fi link
qcom-pcie 1b40000.pcie: PCIe Gen.4 x4 link up        <- NVMe link
nvme nvme0: D3 entry latency set to 10 seconds
ath12k_wifi7_pci 0004:01:00.0: chip_id 0x21 chip_family 0x4 ...   <- Wi-Fi re-initialised each resume
```

`1bf0000.pcie` = Wi-Fi, `1b40000.pcie` = NVMe. Both are re-initialised on resume, and the L2
entry timeout says the link never reached its idle state. The kernel cmdline shows this is not
borrowed from anyone's workaround -- we carry no PCI-skip parameter:

```
BOOT_IMAGE=/boot/vmlinuz-7.3.0-rc5-next-20261002-ec1 root=UUID=... ro acpi=off
clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon
```

PCIe power-down is simply failing on glymur. The sibling A16 project reached the same ground
from the other direction -- they suspend by *skipping* PCIe configuration-space access
altogether, because touching it in `dpm_suspend_noirq()` hard-resets the SoC, and they say of
the result: "devices then never save state or change D-state, **they stay powered through
suspend** -- it sleeps, but saves less power than a correct implementation", adding that
suspend draw has never been measured on their machine.

## The experiment, in order

1. **Baseline.** `sudo bash BRINGUP/tools/a16-suspend-drain.sh mark`, shut the lid ~30 min,
   `report`. That gives Wh and W for the current s2idle path. Everything after is compared
   against it.
2. **`deep`, which has never once run.** `/sys/power/mem_sleep` advertises `[s2idle] deep`;
   `deep` has been entered 0 times, because every attempt before the `0007` xhci guard aborted
   with `-22` before reaching it. `sudo bash .../a16-suspend-drain.sh deep`, then repeat step 1.
   This is the single biggest lever if the firmware implements SYSTEM_SUSPEND properly.
   *Caveat, from the sibling project's notes: they found PCI config-space access in
   `dpm_suspend_noirq()` lethal on this SoC, and a hard reset is a possible outcome. Keep the
   known-good GRUB entry reachable and do not run it with unsaved work.*
3. **Attribute the 2.4 W if `deep` does not help.** With root:
   `sudo sort -rk7 /sys/kernel/debug/wakeup_sources | head -12` (a source with a large
   `total_time` or a non-zero `active_since` is holding the system out of its idle state), and
   compare PCIe states across a suspend. Their tree also carries
   `patches/glymur-suspend-noirq-knobs-DIAGNOSTIC.patch` for exactly this measurement.
4. **Wi-Fi/BT power sequencing.** Their tree carries
   `patches/rc5-20261002/0017-LOCAL-COMPAT-A16-Wi-Fi-and-Bluetooth-power-sequencing.patch`
   as a local compat patch; port it the usual way if the links are implicated.

## What not to conclude

2.4 W for a 66.6 Wh pack is a poor sleep, but it is not a malfunction: the machine slept
correctly, nothing woke it, and the hardware that was expected to power down -- radios, amps,
fans -- did. The gap is in PCIe power management, and it is a kernel/driver problem to fix,
not a configuration mistake to undo.
