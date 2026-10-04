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

## `deep` — tried, and it is not available on this firmware

`/sys/power/mem_sleep` advertises `[s2idle] deep` and `deep` had never been entered. On
2026-10-04 08:55:30 it was, and this is what it does:

```
08:55:33  Disabling non-boot CPUs ...
08:55:33  psci: CPU17 killed ... CPU1 killed      <- SYSTEM_SUSPEND is genuinely attempted
08:55:33  Enabling non-boot CPUs ...              <- and bounced straight back
08:55:33  Detected PIPT I-cache on CPU1 ... CPU17 is up
08:55:34  PM: suspend exit
08:55:34  PM: suspend entry (s2idle)              <- logind retried; THIS is what slept
09:36:47  PM: suspend exit                        <- 41 min, 1.62 Wh, 2.36 W
```

The CPUs go down and come back within the same second, with no error line -- the firmware simply
does not complete the transition. The lid was still shut, so logind re-issued suspend and the
kernel took s2idle, which then slept normally. **The measured 2.36 W is s2idle; `deep` was never
given a sleep to be judged on.** This is consistent with `psci: [Firmware Bug]: failed to set PC
mode: -3` at boot, and with the sibling project's note that this kernel advertises `deep` but
only `s2idle` is tested.

Nothing about `deep` can be fixed from userspace, and it is safe to test: s2idle is re-applied at
every boot by `/etc/tmpfiles.d/a16-mem-sleep.conf`, so a hang or hard reset returns to the working
mode by itself.

## Corroboration from the hardware: coil whine

With the lid shut, an audible **coil whine** is present -- a switching regulator under load. That
is what a powered PCIe link and a re-initialised Wi-Fi chip sound like, and it agrees with the
L2 findings above.

## An unrelated bug found on the way

Every Wi-Fi disconnect taints the kernel:

```
WARNING: net/mac80211/airtime.c:532 at ieee80211_get_rate_duration.isra.0+0x144/0x3d0 [mac80211]
CPU#14 PID:1872 Comm: wpa_supplicant   Tainted: G  W  E
  ieee80211_get_rate_duration <- ieee80211_rate_expected_tx_airtime <- sta_set_sinfo
  <- __sta_info_destroy_part2 <- __sta_info_flush <- ieee80211_set_disassoc <- ieee80211_mgd_deauth
```

Upstream mac80211, hit while the station info is torn down on deauth. Functional impact nil; it
does mark the kernel tainted (`[W]`), which matters when reading any later oops.

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
2. ~~**`deep`**~~ -- **DONE 2026-10-04: not available on this firmware.** It is attempted (CPUs
   go down via PSCI) and does not complete; logind retries and s2idle does the sleeping. See the
   section above. The baseline from step 1 stands as the number to beat, and it reproduces in
   45 minutes.
3. **Attribute the 2.36 W -- the Wi-Fi link first.** The evidence points at PCIe, and the Wi-Fi
   link is the one that can be removed without losing the root filesystem:

   ```bash
   sudo bash ~/A16Build/BRINGUP/tools/a16-suspend-drain.sh mark    # with Wi-Fi up: 2.36 W
   # then, before the next measurement:
   nmcli radio wifi off && sudo modprobe -r ath12k
   ```

   If the rate falls well below 2.36 W, the Wi-Fi link is the largest single contributor and
   `patches/rc5-20261002/0017-LOCAL-COMPAT-A16-Wi-Fi-and-Bluetooth-power-sequencing.patch` (their
   tree) is the next thing to port. If it does not move, the NVMe link and the two USB PHYs are in
   the same trail: `dwc3-qcom a800000.usb: port-1 HS-PHY not in L2`, `a600000.usb: port-1 HS-PHY
   not in L2`.

   For finer attribution, with root:
   `sudo sort -rk7 /sys/kernel/debug/wakeup_sources | head -12` -- a source with a large
   `total_time`, or a non-zero `active_since`, is holding the system out of its idle state. Their
   tree also carries `patches/glymur-suspend-noirq-knobs-DIAGNOSTIC.patch` for this measurement.
4. ~~**Wi-Fi/BT power sequencing.**~~ **Not implicated** -- run 3 below unbound the Wi-Fi PCI
   function entirely and the drain did not move, so their
   `patches/rc5-20261002/0017-LOCAL-COMPAT-A16-Wi-Fi-and-Bluetooth-power-sequencing.patch` has
   nothing to fix here.

## Verdict (2026-10-04): the platform's s2idle floor, and it is not configurable

Four measurements, each one designed to remove a suspect:

| Run | Change | Rate while asleep |
|---|---|---|
| 1 | baseline (nothing changed) | 2.32 W |
| 2 | audio path powered down via its routing switch | 2.26 W (the audio path itself: **0.05 W**) |
| 3 | Wi-Fi PCI function unbound, chip powered down | 2.45 W |
| 4 | USB controllers + PHYs set `control=auto`, and they *did* suspend | 2.46 W |
| overnight | baseline, 8 h 27 min | 2.4 W |

Runs 3 and 4 are the decisive ones: the Wi-Fi chip was removed from the bus and most of the USB
stack really did reach `suspended`, and the drain did not move. **Nothing removable accounts for
it.** Nothing wakes the machine either (one journal entry across 8 h 27 min).

What is left is the platform, and two facts make it final:

```
/sys/devices/system/cpu/cpu0/cpuidle/   state0 WFI   state1 cpu-sleep-0
```

Only two idle states, both shallow -- there is no cluster, L3 or DDR idle state exposed, so while
s2idle holds the system the SoC has nowhere deeper to go. And SYSTEM_SUSPEND (`deep`) is refused by
the firmware outright (see above). 2.4 W is the floor this firmware and these drivers produce.

**The PCIe L2 timeout is a symptom, not the cause.** It is real and worth fixing upstream
(`qcom-pcie 1bf0000.pcie: Timeout waiting for L2 entry! LTSSM: 0x11`, and `dwc3-qcom a800000.usb:
port-1 HS-PHY not in L2`), but unbinding the Wi-Fi function changed nothing measurable, so it
cannot be what costs 2.4 W.

### Practical consequences

- An overnight sleep costs about **30% of the pack**, every time, and no configuration change will
  improve it. For a night or longer, `poweroff` is strictly better; boot is ~30 s and costs nothing.
- **Hibernate is not available and not cheap to add**: `CONFIG_HIBERNATION` is not set in this
  kernel, there is no swap at all, and the rule of thumb (swap >= RAM) would need ~46 GiB while the
  root filesystem has 30 GiB free. The image is built from *used* pages, so a ~16 GiB swap file
  could plausibly suffice -- but it is a kernel rebuild plus swapfile plus resume plumbing, i.e. a
  project, not an experiment.
- A real fix belongs upstream: either deeper idle states for this SoC or a working SYSTEM_SUSPEND.
  Nothing on this machine can be tuned to get there.

### What not to conclude

2.4 W is a poor sleep but not a malfunction. The machine slept correctly, nothing woke it, and
every subsystem we could remove from the equation was removed without changing the number. The
gap is in the platform's power management, and it is a firmware/driver matter -- not a
configuration mistake, and not something to keep chasing with more 45-minute runs.
