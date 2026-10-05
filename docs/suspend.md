# Suspend / resume

**State: the machine resumes, the radio survives it, and the panel comes back by itself — measured
2026-10-02 21:34** (boot `d92a3795`, nothing plugged in): `PM: suspend entry (s2idle)` 21:34:52 →
`PM: suspend exit` 21:34:59, 7 seconds; the Wi-Fi stayed associated and working (`NetworkManager: device
(wlP4p1s0) … Activation: successful, device activated`; `reload_wifi status` = connected, EHT,
576/864 Mbit/s); and the panel came back **dark** (`bl_power=4`, `card*-eDP-1 enabled=disabled`), so the
installed hook `a16-display-wake` restarted gdm 3 seconds later. No SSH, no command, no reboot — at the
cost of the session.

What is still open:

* **The resume leaves the panel dark.** The hook is a workaround; the fix belongs in the eDP resume path
  of `msm`, and that is what would let a resume keep the session instead of forcing a login screen.
* **The one hang on record is unexplained.** 2026-10-02 20:29 (boot `cfa4f2ff`): `s2idle` entry, no exit,
  hard reset — 13 seconds after a failed external DP attach. With nothing attached, the same mode resumes.
* **A partial resume is a different failure mode from a hang.** 2026-10-02 21:42–21:47 (boot
  `d92a3795`): three suspends in one boot; the machine resumed from all of them, the panel came back
  (via the hook, twice) and the power key shut it down cleanly — but the Wi-Fi wedged on the resume
  after the *second* and *third* (`ath12k … wmi command 16387 timeout`, preceded by
  `qcom_mhi_qrtr mhi0_IPCR: PM: failed to resume early: error -5`), so there was no network and no SSH.
  One suspend per boot keeps the radio. See `BRINGUP/evidence/2026-10-02-repeated-suspend-wedges-radio.txt`
  and the Wi-Fi page for the MHI lead.
* **The second and later suspends now go through** — measured 2026-10-02 21:44 and 21:46: both slept
  (~98 s each) with no `-EINVAL` abort at `xhci-hcd.1.auto`. `patches/0010` is doing its job; what the
  later suspends have instead is the radio wedge above.
* **No post-mortem exists on this platform** (no ramoops/pstore backend, no `/dev/watchdog`, lockup
  detectors off), so a resume that never completes leaves the journal ending at `PM: suspend entry` and
  nothing else. `sudo bash ~/a16.sh sleep debug` arms the only live capture there is.

Boot `cfa4f2ff-c099-4483-b966-b7c45f396319` is that hang. See also [wifi.md](wifi.md).

Evidence and quoted logs: `BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt`.

## What "resume works" has to mean here

Two separate things, and only the first is in question:

1. **The machine has to come back.** In the 2026-10-02 case it did not: the journal stops at
   `PM: suspend entry` and nothing after that can run — no hook, no SSH, no script. The `xhci-plat-hcd`
   fix (patches/0010) is the loaded module now — `wifisleep` confirms `a16_skip_unsuspended_hcd=Y` — so
   the second-suspend abort and the dead USB controller are handled for the first time, but whether that
   also changes the resume outcome has not been measured. (The 2026-09-22 ladder shows `s2idle` *did*
   resume then — the radio died, the machine came back.)
2. **The built-in panel has to come back without SSH.** Two ways, and the operator needs to know both:

   * **The keystroke** — Ctrl+Alt+F3, then Ctrl+Alt+F2 (the session's VT). Switching the VT away and
     back makes the compositor do a full modeset when the session is re-activated, which re-enables whatever
     the resume left disabled. The session is only backgrounded for those two seconds; nothing is lost.
     Measured 2026-10-02 21:59 (`dpu_crtc_commit_kickoff crtc110 first commit` as tty2 was re-activated).
   * **The hook** — `sudo bash ~/a16.sh display hook` installs `a16-display-wake`, which runs after every
     resume and, if the panel reads as dark (five seconds after the resume, and again seven seconds
     later), walks a ladder: rung 0 cycles the VT itself (the keystroke, automated), rung 1 asks the
     session to leave power-save via mutter's `PowerSaveMode`, rung 2 restarts gdm as the guaranteed
     fallback. Only rung 2 costs the session.

   A resume can also leave the panel **enabled-but-blank**, which the dark test cannot see (`bl_power=0`
   and `enabled=enabled` while nothing is on screen — 2026-10-02 21:56). For that case there is
   `sudo bash ~/a16.sh display hook always` (`/etc/a16-display-wake.conf`: `A16_ALWAYS=1`), which cycles
   the VT after every resume, before it looks at anything. `hook conditional` puts it back, `hook status`
   says which mode is in force.

## The clean test (nothing plugged in)

    sudo bash ~/a16.sh display hook        # install/refresh the resume hook (the conservative version)
    sudo bash ~/a16.sh sleep test 1        # suspend once; wake with a key, the lid or the power button
    sudo bash ~/a16.sh resume_log          # this boot's suspend/resume lines, one short command

Read the result like this:

| what you see | what it means |
|---|---|
| `PM: suspend entry` … `PM: suspend exit`, panel back on its own | the ideal — the session survives |
| came back, panel dark, then the picture returns within ~15 s | the hook did its job — it cycled the VT or nudged the session, so **your session survived** (check `journalctl -t a16-display-wake`) |
| came back, panel dark, then a login screen a few seconds later | the hook reached its last rung (gdm restart) — no SSH needed, but the session is gone |
| came back, panel blank but `enabled=enabled` | the dark test cannot see this: press Ctrl+Alt+F3 then Ctrl+Alt+F2, or install the `hook always` mode |
| the journal ends at `PM: suspend entry` | the machine never came back. Then: `sudo bash ~/a16.sh sleep debug`, reboot, pick entry [3], suspend — the panel prints the last PM/device lines, which is the only post-mortem this platform has. Afterwards `sleep debug off`. |

Only the last row fails the goal — the machine not coming back. Every row above it leaves you with a
usable machine and no SSH. If a hang does happen, the next lever is the other mode: `s2idle` is what is
persisted in `/etc/tmpfiles.d/a16-mem-sleep.conf` today, and `sudo bash ~/a16.sh wifisleep s2idle off`
selects `deep` (then `sleep test 1` again).

## Did it actually go down?  (the fans are not a measurement)

The EC keeps a fan floor — 1980/1320 RPM at 34 °C on this machine — so hearing the fans during a
"suspend" says nothing by itself. Two numbers do:

* **how long the sleep lasted** (the journal's `PM: suspend entry` → `PM: suspend exit`), and
* **what the battery lost while it lasted**, which turns into an average draw for the window.

`sudo bash ~/a16.sh sleep measure` records both (the before-state goes into the log *before* the
suspend, so even a hard reset keeps it) and gives a verdict: **`< 1 W` = the SoC really powered down**,
`1–3 W` = partly, `> 3 W` = it slept in name only, and a sleep shorter than 5 s = something woke it
immediately. It also dumps the top kernel wakeup sources and the last wakeup IRQ.

**The two modes are not the same thing.** `mem_sleep` is `[s2idle] deep`, and today `s2idle` is what is
persisted (`/etc/tmpfiles.d/a16-mem-sleep.conf`). `s2idle` is a *freeze*: the kernel suspends every
device while the platform stays powered, so the SoC keeps drawing current and the fans keep spinning.
`deep` is PSCI SYSTEM_SUSPEND — the mode that actually cuts the SoC — and is what the suspends that
really powered down used earlier (2026-09-17 evidence). Switch with:

    sudo bash ~/a16.sh wifisleep s2idle off      # deep now, and persisted for every boot

### The immediate-wakeup question (2026-10-02 evening)

Two suspends in the same minute lasted **2 s** and **1 s** (`22:01:29→22:01:31`, `22:01:59→22:02:00`) —
those did not sleep in any useful sense, whatever the power draw was. `pm_wakeup_irq` was `255`, which is
`msmgpio` with `0004:00:00.0:wakeup` (the Wi-Fi's PCIe root port) as the trigger, and several I2C devices
are wakeup-enabled, including the EC (`9-0076`). If a suspend ends by itself in seconds while nothing is
touching the machine, that list is where to look: `sudo sh -c 'sort -k3 -nr /sys/kernel/debug/wakeup_sources | head'`.

The mechanism is now on record — a suspend attempt at `22:10:46` froze userspace and then stopped itself:

    Wakeup pending. Abort CPU freeze
    Non-boot CPUs are not disabled

So there is a wakeup event arriving *during* the suspend, not a failure afterwards. That is a different
problem from the radio wedge, and it is the one that eats the 1-2 s attempts. The count of who fired is in
`/sys/kernel/debug/wakeup_sources` (root only).

### 2026-10-02 late: `deep` sleeps, and the radio dies on its resume too

`sudo bash ~/a16.sh wifisleep s2idle off` selects `deep`; the current default turned out to be `deep` too
once its `s2idle` tmpfiles entry was removed. Two measured attempts:

    22:09:11  PM: suspend entry (deep)  ->  22:10:46  PM: suspend exit    95 s
    22:13:15  PM: suspend entry (deep)  ->  22:14:47  PM: suspend exit    92 s

So `deep` does suspend and does resume — this is the mode to measure for power. **But the radio wedges on
its resume exactly as with `s2idle`**, with the same MHI trail:

    qcom_mhi_qrtr mhi0_IPCR: 20: Failed to receive START channel command completion
    qcom_mhi_qrtr mhi0_IPCR: failed to prepare for autoqueue transfer -5
    qcom_mhi_qrtr mhi0_IPCR: PM: dpm_run_callback(): qcom_mhi_qrtr_pm_resume_early [qrtr_mhi] returns -5

That settles it: the radio wedge is not a consequence of the sleep mode, it is the MHI/QRTR resume path.
Until that is fixed, every resume costs the Wi-Fi (see [wifi.md](wifi.md)).

### What actually wakes it in `deep` (and what does not) — 2026-10-02 22:38

A deep sleep begun at 22:37:59 powered the SoC down properly — the operator confirms the **fans were off**
for the four minutes that followed, which is what "down" looks like — and then nothing woke it: not a short
press of the power button, not opening and closing the lid, not unplugging and replugging the cord. Only
the long press (the firmware reset path) recovered it, and that cost a hard reset.

What is armed:

    pmic_pwrkey    wakeup=enabled     <- the power button, via the PMIC PON block
    gpio-keys      wakeup=enabled     <- the lid switch
    /sys/power/pm_wakeup_irq = 255    <- the msmgpio line whose registered trigger is
                                         "0004:00:00.0:wakeup" = the Wi-Fi's PCIe root port PME

The only wake IRQ this machine has ever recorded is that root-port PME — the same source that aborts
suspends with "Wakeup pending". Hypothesis (testable, not yet proven): **that PME is the only wake source
that actually works in `deep`**, the PMIC and lid paths do not, and the 22:38 sleep became unrecoverable
because the PCI wakeup attributes had just been disarmed (`sleep wakeups off pcie`, 22:37:34) — which
looked harmless, since the power button and the lid stayed armed, but removed the one source that fires.

Consequences, in order of confidence:

1. **Do not disarm the PCI wakeups.** `sleep wakeups off inputs` is still right (input events abort
   suspends and are not needed to wake this machine); `off pcie` may strand it. That is also what the
   reboot undid.
2. **A deep sleep cannot be trusted unattended yet**, and an un-wakeable one costs a hard reset.
   `sleep lid ignore` stops a lid close from starting one.
3. To settle it, one deliberate test: fresh boot (everything re-armed), `deep`, sleep, then a **short**
   press of the power button. If it wakes, the PMIC path works and the 22:38 failure was the disarm. If it
   does not, then neither the PMIC nor the lid wakes this machine from `deep`, and making them work is a
   PMIC/PDC (firmware wake programming) job — the same work that would let `deep` be the daily mode.

### What Windows reaches that we do not: Modern Standby vs our s2idle (2026-10-02)

**Platform identity, which everything below depends on:** this machine is an ASUS Zenbook A16 (UX3607OA),
device tree `compatible = "asus,zenbook-a16-ux3607oa", "qcom,glymur"` — a **Snapdragon X2 Elite (Extreme)
"Glymur"** machine, **not** X1E/Hamoa (`qcom,x1e80100`). Sources quoted from the X1E generation (the Yoga
Slim 7x EC gist, the Ubuntu `x1e80100` fix lists) are neighbouring evidence for the shape of a symptom, never
a statement about this SoC; X2E bring-up is landing upstream right now (this machine's EC driver,
`drivers/platform/arm64/asus-glymur-ec.c`, came from Konrad Dybcio's "Asus Zenbook A16/A14 EC driver" series,
v3 posted days before this kernel snapshot).

The operator's benchmark is right, and it is worth recording precisely because it changes what "fail" means
here. Windows on these Snapdragon X machines does **not** use PSCI deep (S3); it uses **Modern Standby**, which
in Linux's vocabulary is *s2idle* — the same state we select with `mem_sleep`. So the state is the right one.
What Windows has and this Linux setup does not is the **platform sleep integration**:

* **No ARM64/Qualcomm s2idle entry.** `s2idle_set_ops()` is called only from `drivers/acpi/sleep.c` and
  `drivers/acpi/x86/s2idle.c` in this tree — i.e. only x86/ACPI platforms implement the low-power entry.
  Without it, s2idle freezes the devices, idles the CPUs **inside a fully powered SoC** and returns: no sleep
  vote, no SoC power state, and nothing the EC reads as "host asleep" (which is exactly why the fans stay at
  their floor in s2idle and stop in deep).
* **No always-on sleep path in the DT.** This machine's device tree has no AOP/AOSS-style node at all (top
  level: `pmic-glink`, `smp2p-{adsp,cdsp,soccp}`, `remoteproc@d00000` = `soccp` attached, `6800000` = adsp,
  `32300000` = cdsp), and nothing in `drivers/soc/qcom/` hooks `PM_SUSPEND_PREPARE`/`PM_POST_SUSPEND`. So no
  driver sends the sleep votes to an always-on processor at suspend — on the machines where s2idle does save
  power, that is what does it. (`qcom_aoss_qmp` is bound, but has no counterpart node in this DT.)
* Present and correct: the AOSS RSC (`rsc@18900000`, `qcom,drv-id = 2`) with `rpmh-rsc.c`'s suspend-time
  wakeup handling, and a bound PDC (`b220000.interrupt-controller`), plus the lid declaring `wakeup-source`
  and `pm8941-pwrkey` calling `enable_irq_wake()` — the wake sources are armed as IRQs, nothing turns that into
  a SoC wake.

Consequence, plainly: **s2idle here is a shallow freeze, not Modern Standby**, and **deep powers the SoC down
but has no working wake path**. Closing the gap means implementing the sleep/wake entry (wake-source latching
and the sleep votes) — driver and DT work, not a configuration line. Windows proves the hardware and firmware
can do it, so it is a code problem and not an impossibility; it is also not small.

What that leaves usable today: **s2idle + the display hook + the radio's resume fix** gives "close the lid,
open it, everything back" *without* the power saving; **deep** gives the power saving *without* the wake.
Until the sleep entry exists, `lid ignore` + `wifisleep s2idle on` is the safe configuration.

#### The EC half is already upstream and active on this machine (2026-10-02)

The "tell the EC the host is suspending" handshake that Modern Standby depends on is **already in this kernel
and bound on this machine** — unlike the Lenovo Yoga Slim 7x, where the EC node had to be hand-patched into the
DTB inside a signed UKI (gist `gist.github.com/radixcl/c2c9c5fcf83a1d28eaba6c59857b7837`; it measures
**5.4 W → 3.2 W** once the EC is notified, and states plainly that the remaining ~3 W floor is "the known
platform-wide X1E limitation (SoC never reaches its deepest suspend states)"). That is an independent
measurement of the same **shape** as what we see — s2idle shallow, fans up, the EC needing its notification —
on the *previous* generation. It is not evidence about glymur, and X2E is far less covered; do not quote it as
this platform's known limit.

This machine is an **ASUS Zenbook A16 UX3607OA**; linux-next carries `drivers/platform/arm64/asus-glymur-ec.c`
(compatible `asus,zenbook-a16-ux3607oa-ec`, and `qcom-hamoa-ec.c` alongside it) and the EC at i2c `9-0076` is
bound to it. Its PM ops write the EC's Modern Standby register:

    asus_glymur_ec_suspend() → i2c write 0x23 ← 0x07  (ASUS_QCOM_EC_MODERN_STANDBY_ENTER)
    asus_glymur_ec_resume()  → i2c write 0x23 ← 0x08  (ASUS_QCOM_EC_MODERN_STANDBY_EXIT)

The write's return value is propagated, so a failed notification would surface as a device suspend failure in
the journal — none appears in our suspend/resume logs, so the EC is being told. **The fans staying up in s2idle
is therefore the SoC-side floor, not a missing EC handshake**: nothing to patch on the EC side for this
machine. The remaining work is the SoC sleep/wake entry above (and, upstream, the RPMH RSC sleep/wake-TCS
series, which this tree does not yet contain).

### The abort lever: the root ports' PME (test pending, 2026-10-02)

The kernel enables a device's PME at suspend whenever `device_may_wakeup()` is true (`drivers/pci/pci-driver.c`),
and both root ports have `power/wakeup = enabled`. So `0004:00:00.0` (the Wi-Fi's bridge) has its PME enabled
through suspend, and the PME it forwards is what aborts the deep attempts — `Wakeup pending. Abort CPU freeze`
with `pm_wakeup_irq` = the `msmgpio` line registered as `0004:00:00.0:wakeup`. The targeted test is to disarm
**only the bridges**, leaving the power button, the lid and the input devices armed:

    sudo bash ~/a16.sh sleep wakeups off ports     # the two bridges only (0004/0005:00:00.0)
    sudo bash ~/a16.sh sleep measure               # deep: does it still abort?  does the power key wake it?

* abort stops and the machine still wakes → `deep` becomes usable; the remaining work is the radio
* abort stops and the machine no longer wakes → the port's PME was doing the waking, and the PMIC/lid wake
  paths (PMIC/PDC firmware wake programming) are what to fix

The configuration that must **not** be used is disarming everything (`wakeups off all`): that is what stranded
the 22:37 sleep, because it removed the only source that had ever recorded a wake.

### The shutdown/reboot that never completes

A shutdown reaches `systemd-shutdown: Sending SIGTERM to remaining processes...`, the journal closes, and
the machine stays on — held there by something after userspace, in the kernel's device teardown or the
final PSCI poweroff. There is no post-mortem on this platform, so the console is the instrument:

    sudo bash ~/a16.sh sleep debug shutdown     # entry [3] gains initcall_debug + ignore_loglevel
    # reboot, pick [3], then shut down and WATCH THE PANEL

With `initcall_debug` the kernel names every device as `device_shutdown()` walks them
(`drivers/base/core.c`), so the last name printed before it stops is the device that hangs. Write it down;
then `sudo bash ~/a16.sh sleep debug off`. Candidates by inspection: the msm DRM shutdown
(`msm_kms_shutdown` → `drm_atomic_helper_shutdown`, which does a modeset and waits), `mhi_pci_shutdown`,
and the 56 `.shutdown` callbacks under `drivers/usb/host` — with the possibility that it is not a driver at
all but the platform refusing the final poweroff.

## The lid is not the problem

The device tree declares a lid switch under `gpio-keys` (`switch-lid`, `SW_LID`, `wakeup-source`), it is
the only `EV_SW` device on the machine (`/sys/class/input/event0/device/capabilities/sw` = `1`), and
`systemd-logind` watches it and logs both transitions:

    systemd-logind: Watching system buttons on /dev/input/event0 (gpio-keys)
    systemd-logind: Lid closed.
    systemd-logind: Lid opened.

`HandleLidSwitch` is the systemd default, `suspend` (no `/etc/systemd/logind.conf.d/` exists). There is
no ACPI lid device (`/proc/acpi/button/lid` is absent, `acpi=off`), which is why the GPIO switch is what
logind uses.

## What the two kinds of attempt look like

Boot `3a63a313`, the sequence that ends in a reboot:

    kernel: PM: suspend entry (deep)          12:33:19     <- first suspend of the boot
    ... 88 minutes ...
    kernel: Freezing user space processes     14:01:29
    kernel: ath12k_wifi7_pci 0004:01:00.0: PM: failed to resume async: error -110
    kernel: PM: suspend exit
    kernel: PM: suspend entry (s2idle)
    kernel: xhci-hcd xhci-hcd.1.auto: PM: dpm_run_callback(): platform_pm_suspend returns -22
    kernel: xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
    kernel: PM: Some devices failed to suspend, or early wake event detected
    kernel: PM: suspend exit

and then, every ~33 s while the lid stayed shut, `Suspending...` / `Operation 'suspend' finished.` 3 s
later in `systemd-logind`, each one the same two aborts. Boot `20167034` repeats the pattern exactly
(11:44:06 entry, 12:03:06 resume, all later attempts aborting).

### Why the abort happens

`-22` is `-EINVAL` from `xhci_suspend()` (`drivers/usb/host/xhci.c`, in the tree we build from):

    if (hcd->state != HC_STATE_SUSPENDED ||
        (xhci->shared_hcd && xhci->shared_hcd->state != HC_STATE_SUSPENDED))
            return -EINVAL;

The USB core has not left the HCD in the suspended state that callback requires — true on the first
attempt of a boot, false on every attempt after a resume. The controller is `xhci-hcd.1.auto`
(`io mem 0x0a400000`, `usb@a400000`, a USB2 + USB3 root-hub pair); the only device on it is a USB mass
storage device (`0bda:0329`, `usb-storage`, on the SuperSpeed bus).

`mem_sleep` is `s2idle [deep]`, so a suspend is attempted as `deep` first; when that aborts, `s2idle` is
tried and aborts the same way, on the same device, so `s2idle` is not a working fallback here.

## What the machine does about it

- Lid shut: the machine does not sleep; the fans run and the battery drains ~10 %/h (~6-7 W idle on a
  66.6 Wh pack). Nothing in userspace can suspend once the controller is in that state.
- Lid open: logind stops retrying.
- The retry loop and the idle draw are the same symptom, so `HandleLidSwitch=ignore`
  (`sudo lid_sleep lid ignore`) removes the pointless attempts but does not produce sleep:
  only a working suspend does.
- **The one suspend that works takes the Wi-Fi firmware with it.** On its resume, `ath12k` fails to
  restart the radio (`failed to resume core: -110`), after which the WMI channel never answers again and
  the interface cannot come up: no scan finds anything, and there is no software recovery — the
  driver-teardown ways out hang the machine ([wifi.md](wifi.md) has the table). So a closed lid means
  either an awake machine with a working radio (`lid ignore`) or one sleep and a reboot afterwards.

## The fix that is staged: `patches/0010` (xhci-plat-hcd.ko)

The failure is one controller refusing to suspend, and it takes the whole system suspend with it. The
only loadable module on that path is `xhci-plat-hcd.ko`, so the workaround is there: when
`xhci_suspend()` returns `-EINVAL` because the USB core never left the HCD suspended, leave the
controller running (and skip the matching resume) instead of failing the system suspend, while logging
`hcd->state`, `hcd->flags`, both root hubs' states, `device_may_wakeup()` and `xhci->quirks` at every
transition. Reasoning, the three candidate root causes and what each would need:
`BRINGUP/notes/2026-09-17-xhci-second-suspend.md`; patch:
`retired/patches/old-numbering/0010-xhci-plat-a16-skip-unsuspended-hcd.patch`.

    sudo bash ~/a16.sh suspendfix            # install (checks vermagic + every import CRC first)
    sudo bash ~/a16.sh suspendfix status     # installed? loaded? which module parameters are live
    sudo bash ~/a16.sh suspendfix revert     # back to the stock module

It is verified as an ABI match for this kernel (vermagic `7.3.0-rc3-next-20260914 SMP preempt
mod_unload modversions aarch64`, 62 imports identical, `module_layout` CRC `0xe6658f7b`), it is
*staged* — the machine has to reboot for it to be the loaded module, and until `lid_sleep test 2`
shows both attempts sleeping it is not "verified on the machine". Two module parameters switch it and
its logging at runtime:

    /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd
    /sys/module/xhci_plat_hcd/parameters/a16_state_log

What it costs: the USB controller is left running while the system sleeps (its own root cause is not
fixed, only its effect on the system suspend), and it does not help the Wi-Fi wedge, which is a
separate resume failure of `ath12k` ([wifi.md](wifi.md)).

## Tools

`BRINGUP/tools/a16-sleep-test.sh`, reachable as `sudo lid_sleep`:

| mode | what it does |
|---|---|
| (default) `status` | read-only, no root: `mem_sleep`, the logind policy and its lid lines, the suspend attempts of this boot, the controller that aborted them, and the USB devices with their wakeup flags |
| `test [n]` | suspends for real, `n` times, and reports after each attempt whether the machine slept, with the kernel lines and the device that stopped it |
| `lid ignore` / `lid suspend` | writes `HandleLidSwitch` (and `HandleLidSwitchExternalPower`) to `/etc/systemd/logind.conf.d/50-a16-lid.conf` and reloads logind |

Log: `~/a16-payload/sleep-test-<timestamp>.log`.

`sleep test 2` is the reproduction of the historical evidence: the first attempt slept and the second
aborted at `xhci-hcd.1.auto`. Re-run it now that `patches/0010` is loaded and see whether the abort is
gone.

The other half of the story is what a resume leaves behind. `BRINGUP/tools/a16-resume-recover.sh`,
reachable as `sudo bash ~/a16.sh resume`:

| mode | what it does |
|---|---|
| (default) `status` | read-only, no root: the panel, the USB controllers and what is on them, the radio's PCIe link, the power source, and the suspend/resume history of the last four boots |
| (root,no args) | the soft repairs: panel (unblank, and restart gdm only if the panel is really dark), USB (re-authorise devices that did not come back), Wi-Fi (NetworkManager + supplicant) |
| `panel` / `usb [hard]` / `wifi` | one half only; `hard` adds the rungs that can hang this kernel and needs `A16_I_KNOW=1` |
| `hook install` / `remove` / `status` | run the soft repairs automatically after every resume |

Log: `~/a16-payload/resume-recover-<timestamp>.log` (the hook appends to `resume-recover-hook.log`).

## Still open

- **Which mode this machine actually resumes from.** `mem_sleep` is `[s2idle] deep`; the 2026-10-02 hang was
  `s2idle`. Test both deliberately — `sudo bash ~/a16.sh wifisleep s2idle off` selects `deep` — before
  trusting either with a closed lid.
- **The hang cannot be post-mortemed on this platform** (no ramoops/pstore backend, no `/dev/watchdog`, both
  lockup detectors off), so the journal simply stops at `PM: suspend entry`. Only a live capture can show
  where it stalls: `no_console_suspend` on a test boot entry, or the panel itself with `consoleblank=0`.
- **Whether a failed external-DP attach immediately before the suspend is what poisons it.** In the 20:29
  case the last two kernel lines before the suspend were `link training #2 on phy 0 failed. ret=-110` and
  `link training on sink failed. ret=-110`; the attach itself was contained (two lines, no DPU
  timeout storm — `patches/0020` doing its job) and the lid closed 13 s later.
- **The radio wedge is not recoverable in software.** `reload_wifi --help` records that the module reload
  (`modprobe -r`) froze the machine and needed a hard reset; `a16_keep_mhi_up=Y` is what prevents the wedge,
  and `a16.sh resume` refuses the teardown rungs by design.
- The eDP panel through a suspend: `a16.sh display hook` restarts gdm when a resume leaves it dark, and
  `a16.sh resume` does the same only when the panel is actually dark.
- logind's retry interval (~33 s) is what turns one broken suspend into continuous wakeups; the only knob
  for it is the lid policy.
- `BRINGUP/NEXT-STEPS.md` item 5 is the work item.
