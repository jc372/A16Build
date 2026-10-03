# Platform resume investigation, 2026-10-02 late (boot 01bd23bd)

## Platform identity first, because it changes how every source below may be used

This machine is an **ASUS Zenbook A16 (UX3607OA)**, device tree
`compatible = "asus,zenbook-a16-ux3607oa", "qcom,glymur"` — i.e. a **Snapdragon X2 Elite (Extreme),
"Glymur"** machine. It is **not** X1E/Hamoa (`qcom,x1e80100`). Everything on it is named for
glymur: `gcc-glymur`, `qnoc-glymur`, `gpucc-glymur`, `gpucc_glymur`, firmware under
`/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/`, and the EC driver matches on
`asus,zenbook-a16-ux3607oa-ec`.

Consequence for sources: the X1E-era community material — the Yoga Slim 7x EC gist (whose "~3 W floor
is the known platform-wide X1E limitation" line has been quoted in this repo), the Ubuntu x1e80100 fix
lists, the x1e80100 display-resume reports — is **neighbouring evidence**: it describes the *shape* of
a symptom on the previous generation and is worth reading, but it is never a statement about this SoC.
Our platform is newer and far less covered, and in fact its bring-up is landing upstream right now:
`drivers/platform/arm64/asus-glymur-ec.c` comes from Konrad Dybcio's "Asus Zenbook A16/A14
(UX3607OA/UX3407NA) EC driver" series (v3 posted days before this kernel snapshot), together with
`arm64: dts: qcom: glymur-zenbook-a16: Add Embedded Controller`. That is why a machine this new both
has a driver for its exact EC and is otherwise half-broken.

Follow-up to `BRINGUP/evidence/2026-10-02-s2idle-keepmhi0-radio-still-dies-usb-too.txt`, which showed
that in one resume pass **two unrelated devices** failed with `-110` (ath12k and
`dwc3-qcom a600000.usb`). That makes the resume failure a platform problem, so this is what the
platform side actually looks like.

## The `sync_state() pending` messages: structural, permanent, and a power issue — not the cause

The boot log says:

    qnoc-glymur interconnect-1: sync_state() pending due to 1dfa000.crypto
    qnoc-glymur 16e0000.interconnect: sync_state() pending due to 1dfa000.crypto
    gcc-glymur 100000.clock-controller: sync_state() pending due to 3d6c000.gmu
    gpucc-glymur 3d90000.clock-controller: sync_state() pending due to 3d6c000.gmu

Both consumers can never probe, so these are not a transient boot race:

* **`3d6c000.gmu` has no driver at all**, by design — the GMU is driven from inside the adreno/msm
  driver, which is *working* (`[drm:adreno_bind [msm]] Found GPU: 44070001`, GMU firmware v5.2.38
  loaded). The platform device exists in sysfs and stays unbound forever; fixing it is an upstream DTS
  matter (the node references the clock controllers but nothing binds to it).
* **`1dfa000.crypto` (QCE) is not built**: `CONFIG_CRYPTO_DEV_QCE` is absent from the running config,
  so the device exists and never binds. This half is within our control — enable the driver and that
  consumer disappears.

What it *costs* is narrower than it appears. `icc_sync_state()` (`drivers/interconnect/core.c`) is the
mechanism that **drops the bootloader's bandwidth votes** — it zeroes each node's `init_avg`/`init_peak`,
re-aggregates and re-applies. Until it runs, the NoC holds the firmware's boot-time votes, i.e.
resources stay *on* rather than going unmanaged. A never-completing `sync_state()` is therefore a
**power** anomaly (part of why nothing reaches a low-power state) and worth cleaning up, but it does
**not** explain a device timing out at resume. Half-right lead: keep it for the power side, drop it as
the resume cause.

## What the resume failure still is

A cluster of `-110` timeouts in one resume pass, across unrelated devices:

* `ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110` / `PM: failed to resume async`
* `dwc3-qcom a600000.usb: PM: failed to resume: error -110`
* (earlier boot) `qcom_mhi_qrtr mhi0_IPCR: failed to prepare for autoqueue transfer -5`,
  `PM: failed to resume early: error -5`

Not yet excluded: the RPMH power domains (`rpmhpd`) for the shared rails, the SMMU/IOMMU context, and
the resume ordering itself. Our own A16 ath12k patch documents (core.c, around
`ath12k_core_suspend`) that *upstream's* resume path times out in exactly this situation, so the Wi-Fi
driver is a symptom here, not the origin.

**The instrument for this is already built**: `sudo bash ~/a16.sh sleep debug` arms entry [3] with
`initcall_debug pm_debug_messages no_console_suspend`, which prints every device's resume with
timings — the resume timeline, showing where the stalls are and what precedes them. It costs one
suspend, and with the radio wedged that means one reboot, so it is worth one deliberate run.

## Found while researching: a display-resume fix of the same class as our VT workaround

Our stand-in for a display-recovery on resume is Ctrl+Alt+F3 → back, which forces a full modeset. An
upstream msm patch, `drm/msm/dpu1: don't choke on disabling the writeback connector`, describes that
exact symptom — reported on **X1E** machines (x1e80100 CRD, Lenovo ThinkPad T14s), so it is
neighbouring evidence rather than an established glymur bug:

    "During suspend/resume process all connectors are explicitly disabled and then reenabled.
     However resume fails because of the connector_status check ..."
    "Without this patch, the internal display fails to resume properly (switching VT brings it back)"

Next action: check whether our patched `msm` carries that fix, and if not, decide on it through the
gated build path. The DPU code is shared between the generations, so it is a cheap check and would be
the first change in this work that makes the resume *better* rather than better-understood.

## THE MECHANISM: s2idle on this platform can cut power to devices (upstream's own words)

Upstream is working on exactly this quirk, and the description names our family:

    [RFC PATCH 0/1] soc: qcom: rpmh-rsc: Register s2idle_ops to indicate s2ram behavior in s2idle

      "This is just an attempt to let the device drivers know of the quirky platform behavior of
       mimicking s2ram in s2idle for older Qcom SoCs (pre-Hamoa and non-chromebooks) using RPMh. This
       information is important for the device drivers as they need to prepare for the possible power
       loss during system suspend by shutting down or resetting the devices."
      (thread: https://lkml.indiana.edu/2601.0/05753.html -- the discussion also notes that on these
       targets the PCIe side loses power in that state, and that on the newer parts a real s2ram
       feature is appearing where the SoC does power off)

Our tree does not contain it: `grep s2idle_set_ops drivers/soc/qcom/*.c` finds nothing (the only
callers in the tree are ACPI/x86).

**This explains every measurement in the evidence file:**

* s2idle on this platform can **drop power to the Wi-Fi endpoint** while the PCIe *link* (held by the
  platform's sleep power) survives. That is exactly what was measured: link 8.0 GT/s, state D0, driver
  bound, `wlP4p1s0` present — and firmware dead. It also explains the `-110` from the USB controller
  in the same pass: a device that lost power, whose driver assumed it had not.
* Our own A16 ath12k patch is built on the **opposite** assumption. `ath12k_pci_power_up()` says so on
  resume — "A16: resume -- not resetting the device (MHI state 0x%x); the firmware should still be
  running" — and sets `ATH12K_FLAG_A16_KEPT_DEVICE`, while `ath12k_mhi_stop(is_suspend=true)` uses
  `mhi_power_down_keep_dev()` on purpose. Both assume survival, which this platform does not promise.
  **Our own patch is therefore a large part of why the radio dies.**

So the fix is the one the RFC prescribes: prepare for power loss — treat a system suspend as a power
cycle.

### The build (next action)

`a16_fix_level` is only a marker of the highest local fix, not a mode selector, and no existing knob
does a full power cycle — so this needs a build, through the gated path
(`BRINGUP/tools/a16-build-gpucc-native.sh` plus `a16-abi-layout-gate.sh`), as a third mode alongside
the two we have:

1. suspend: `ath12k_mhi_stop(ab_pci, is_suspend=true)` → `mhi_power_down()` (full, device reset)
   instead of `mhi_power_down_keep_dev()`, so the device is genuinely shut down before the platform
   cuts power.
2. resume: in `ath12k_pci_power_up()`, do **not** take the "not resetting the device" branch; do the
   full cold bring-up (`mhi_prepare_for_power_up()` + `mhi_sync_power_up()`) and let the existing
   restart/crash-recovery path reload the firmware (QMI → firmware download) — while keeping
   `a16_skip_global_reset_on_resume=Y`, since the SoC global reset is what produced the `-22` in the
   original attempt.
3. keep `a16_keep_mhi_up=Y` and the re-attach mode selectable so all three can be compared.

Test: s2idle (the safe mode) with `sleep measure`, then `reload_wifi status`. Either the radio comes
back on resume — the platform really cut power and we now re-initialise correctly — or the failure
moves somewhere informative (e.g. a firmware download against a device that is still powered). Both
answers are progress.

## Also seen

`msm_dp_pm_runtime_resume` / `msm_dp_pm_runtime_suspend` looping dozens of times per second after a
resume (23:28:54, `type=10 core_init=0 phy_init=0`). Unexplained; worth its own look since it burns
power exactly when we are trying to save it.
