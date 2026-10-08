# Sleep does not suspend: console-suspend stalls for minutes, then the device phase aborts (2026-10-07)

Reported as "sleep keeps the fans on". Measured: **the machine never enters the low-power state at all.** The
screen goes off, the SoC stays awake, the EC keeps its fan curve running.

## The timeline says exactly where it goes wrong

    boot -1 (10-07):
      11:39:55  PM: suspend entry (s2idle)
      12:31:26  printk: Suspending console(s) (use no_console_suspend to debug)
      12:31:26  xhci-hcd xhci-hcd.1/2.auto: A16 suspend: hcd state=4 ... wakeup=0
      12:31:26  hwmon hwmon110: PM: parent phy0 should not be sleeping
      12:31:26  PM: suspend exit

    previous attempt (10-06):
      15:53:17  PM: suspend entry (s2idle)
      15:57:38  Freezing user space processes / ... / PM: suspend exit     (same second)

Two independent failures, in this order:

1. **The console-suspend step blocks for minutes to tens of minutes.** The gap is entirely *before* the freeze:
   4 m 21 s on 10-06 and **51 m 31 s** on 10-07. `pm_prepare_console()` -> console suspend is the step between
   "suspend entry" and "Suspending console(s)", and on this machine the console is `fbcon` bound to `msdrmfb`
   with `keep_bootcon` on the cmdline, on a display stack with known flip/lock trouble. That is the whole
   awake-with-fans window.
2. **Then the device phase fails and the suspend aborts immediately.** `hwmon hwmon110: PM: parent phy0 should
   not be sleeping` — the Wi-Fi PHY's hwmon, i.e. the ath12k cluster from
   `notes/2026-10-02-platform-resume-investigation.md` (ath12k `-110`, `dwc3-qcom a600000.usb`, `mhi0_IPCR -5`).
   `PM: suspend exit` lands in the same second, so s2idle never idles.

Supporting platform facts: `/sys/power/state = freeze mem`, `/sys/power/mem_sleep = [s2idle] deep` (s2idle in
use; `deep` is advertised but untested — a failed S3 resume on a half-brought-up platform means a hard reset, so
treat that as a deliberate, prepared experiment, not a quick poke). cpuidle itself works: WFI plus
`cpu-sleep-0` with 7 641 s accumulated, so cores do idle-sleep — the platform-level suspend is what's missing.

## Correction: the touchpad wakeup count is a red herring

`/sys/class/wakeup` showed the touchpad (`0-0015`, `touchpad@15`, i2c-HID) at 84-89 k events, four orders of
magnitude above everything else. That looks like a storm and is not one: sampled live it is 0 events/s, and the
cumulative figure over 7 901 s uptime is ~11/s average — i.e. ordinary use. `active_count == event_count` means
each event activates and deactivates cleanly, so there is no leak either. Its pin config (`gpio3`,
`function="gpio"`, `bias-disable`) is byte-identical to the Yoga Slim 7x's, so the DT is not aberrant. Nothing
here is preventing sleep.

## Test plan (all of it safe)

1. `sudo bash ~/a16.sh sleep debug` — arms entry [3] with `initcall_debug pm_debug_messages no_console_suspend`.
   That flag is what the kernel itself asks for, and it does two useful things: it keeps the console alive so
   the messages survive, and it *skips* the console suspension — i.e. it both diagnoses and bypasses failure #1.
   Boot that entry, suspend, read the timeline. If the stall disappears, the console path is confirmed as the
   blocker and the question becomes what holds the console lock (likely the same display stack as the wedge
   work).
2. In that boot, watch the device phase: with the console stall gone, does it idle, or does the ath12k/`phy0`
   failure still abort it? If it still aborts, unload the Wi-Fi (`modprobe -r ath12k`) and retry — that isolates
   the abort to the Wi-Fi cluster.
3. If `no_console_suspend` is what makes sleep work, it is a reasonable permanent line for this machine anyway:
   the cmdline already asks for a visible console (`console=tty0 keep_bootcon loglevel=7`).

## Not to forget alongside this

- The NoC `sync_state()` never completes (unbound `1dfa000.crypto` — `CONFIG_CRYPTO_DEV_QCE` is not enabled —
  and `3d6c000.gmu` which has no driver by design), so the bootloader's bandwidth votes are never dropped and
  resources stay voted on: a power anomaly, per the 2026-10-02 note. The QCE half is ours to fix in the config.
- The PDP0/CPUCP firmware does not implement SCMI perf at all (`notes/2026-10-07-cpufreq-scmi-perf-missing.md`),
  so there is no CPU DVFS either. Idle power on this machine is missing on both ends — frequency control and
  platform suspend — which is why "warm at idle" and "fans on while asleep" are the same story.
