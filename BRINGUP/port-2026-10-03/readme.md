# A16 on linux-next `next-20261002` — minimal forward-port

Target: **`7.3.0-rc5-next-20261002`** — the linux-next snapshot this port builds.
Machine: ASUS Zenbook A16 (UX3607OA). Maintainer of this directory: agentbhome.

This directory is self-contained: this readme, the patch set for this release, and
`build.sh`, which reproduces the build. All paths are relative to this directory.

---

## 1. The rule

**Nothing is carried unless this linux-next is measurably missing it.**

Every candidate is tested one way, against a *pristine* copy of this release extracted
from its own tarball:

    patch -p1 --dry-run --forward --batch -d <pristine-tree> < patch

    APPLIES            upstream lacks it            -> carry
    ALREADY UPSTREAM   upstream already has it     -> do not carry
    CONFLICTS          upstream moved the same code -> rebase, or drop
    target absent      not a source patch          -> see §4

The dry-run must run against a **pristine** tree. Against a tree that already has your
patches in it, it reports your own work back as "already upstream" and is worthless.

## 2. Verdicts, measured against pristine `next-20261002`

### Carried — upstream lacks them and the patches apply cleanly

| patch | what it fixes | symptom when absent |
|-------|---------------|---------------------|
| `0015-qmp-combo-glymur-v5` | Type-C/DP combo PHY | external monitor plug-in **restarts the machine** |
| `0010-xhci-plat-a16-skip-unsuspended-hcd` | USB host, same path | part of the same monitor failure |
| `0017-qmp-v8-refresh-pcs-drive-on-training` | combo PHY PCS on training | external display link |
| `0018-msm-dp-lttpr-segment-training` | eDP link training segments | external display link |
| `0011-dt-bindings-asus-zenbook-a16-ec` | EC binding documentation | EC does not bind |
| `0012-platform-arm64-asus-glymur-ec` | the EC driver (upstream has no such file) | no lid switch, power button, internal input bus |
| `0013-arm64-dts-glymur-zenbook-a16-ec` | the EC node in the DTS | no EC at `i2c 9-0076` |
| `0014-ath12k-a16-no-soc-global-reset-on-resume` | ath12k resume | Wi-Fi does not survive resume |
| `0016-ath12k-refuse-device-after-failed-resume` | ath12k error path | bad state after a failed resume |
| `0016-drm-msm-attach-a-driver-to-the-gmu` | binds the GMU as its own driver | upstream series (RFT at the time of writing): without it the GMU is left without a bound driver, so `3d6c000.gmu` reports `sync_state() pending`. Carries the definitions of `adreno_gmu_register()`/`adreno_gmu_unregister()` that the rest of the tree calls. |

### Carried — the reverse case: upstream has the code and we gate it off for this part

| patch | what it does | why |
|-------|--------------|-----|
| `0015-drm-msm-a8xx-gate-clx-thinmem-hfi-exchanges` | skips the `a6xx_hfi_enable_clx()` and `a6xx_hfi_send_thinmem_config()` HFI exchanges on x285 | linux-next sends both unconditionally. The `gen80100_gmu.bin` v5.2.38 this part ships with does not accept them: it raises its FW_INIT error flag (`0x00000900` instead of the clean `0x00000100`) and then never acks the following GX bandwidth vote, so GPU bring-up fails with `-110`. Gated off, the 3D stack comes up (render node, hardware EGL, devfreq live). Open upstream question: how the capability should be detected. |

### Needs a rebase before it can be carried

| patch | conflicts |
|-------|-----------|
| `0015-ath12k-a16-reattach-driver-after-kept-device-resume` | 7 hunks |
| `0016-dp-external-rate-and-failed-enable-guard` | 2 hunks |
| `0017-ath12k-idempotent-thermal-cleanup` | 2 hunks |
| `0018-ath12k-keep-mhi-up-across-suspend` | 3 hunks |

### Not carried

* `0008` msm skip-push-idle — **already upstream**; against a pristine tree the patch
  reports *already applied*.
* `0001`, `0003`, `0019`, `0020` — not source patches; see §4.
* the ath12k resume group is optional on a machine that does not suspend.

## 3. What upstream is missing, stated positively

Three fixes exist here and nowhere in this release:

1. **The A16's embedded controller.** Upstream has no `drivers/platform/arm64/
   asus-glymur-ec.c` and no node for it. Without it there is no lid switch, no power
   button, and the internal input devices have no parent bus.
2. **The eDP v8 power-on sequence.** Upstream's `drivers/phy/qualcomm/phy-qcom-edp.c`
   contains none of `prepare_power_on_v8`, `configure_tx_pre_pll_v8`,
   `finish_power_on_v8`, `configure_rate_pcs_v8`. Its v8 path only works for 4-lane
   8.1 Gbps; this machine is 2-lane 5.4 Gbps and the link does not train. `0006` applies
   cleanly; `0007` needs a rebase.
3. **The combo-PHY behaviour the external display needs.** Plugging a monitor in
   restarts the machine without it.

## 4. Things that look like patches but are not

`0001`, `0003`, `0019` and `0020` report "target absent" because their paths are scratch
names from a DTB-patching workflow — for example
`glymur-asus-zenbook-a16-ux3607oa.dts` -> `glymur-a16-bt-test.dts` — not tree paths. They
are not part of the source build. Where one encodes a real device-tree delta, it is
carried as an ordinary patch against the tree's DTS (§5).

## 5. Bluetooth

Not working, and not for want of configuration: this build has `BT=m`, `BT_HCIUART=m`,
`BT_HCIUART_SERDEV=y`, `BT_HCIUART_QCA=y`, and the firmware is installed system-wide in
`/lib/firmware/qca`.

What is missing is the device-tree **serdev client**. `uart14` (`a98000.serial`) is a
serdev controller, so its tty is deliberately hidden from userspace and `btattach`
cannot open it. `hci_qca` binds a serdev *client*, and upstream's DTS gives `&uart14`
only a `port` graph child. A node of this shape is required:

    &uart14 {
        bluetooth {
            compatible = "qcom,wcn7850-bt";
            max-speed = <3200000>;
            /* six supplies hci_qca asks for and this DTS does not describe:
               vddio 1.8V, vddaon 0.6V, vdddig 0.85V, vddrfa0p8, vddrfa1p2, vddrfa1p9.
               Stubbed here as always-on fixed regulators so the driver is satisfied --
               the rails are very likely already powered, since WLAN on the same module
               works. The rails still have to be mapped for real before this is more
               than a test. */
        };
    };

## 6. State of this release, as measured

Working: display (connected, 2880x1800, `dp_aux_backlight`), internal input (Asus
Keyboard, hid-over-i2c touchpad, stylus), the EC at `i2c 9-0076`, Wi-Fi, sshd.

Not working at the time this list was taken (all three are fixed by the patches that follow;
the list is kept as the record of what the port was for):

* **Bluetooth** — §5.
* **External monitor** — plugging one in restarts the machine (§2).
* **3D GPU** — `a6xx_gmu_start: GMU firmware initialization timed out`, then
  `Couldn't power up the GPU: -110`. The panel does not need the GMU, so the display is
  unaffected, but GL applications fall back to software rendering. Fixed by
  `0015-drm-msm-a8xx-gate-clx-thinmem-hfi-exchanges`: linux-next sends two HFI exchanges
  (`a6xx_hfi_enable_clx()`, `a6xx_hfi_send_thinmem_config()`) that `gen80100_gmu.bin` v5.2.38
  will not acknowledge, so they are gated for this chip and the GPU comes up.

One configuration point is easy to lose and fatal: this release declares

    config CLK_GLYMUR_GPUCC
        default m if ARCH_QCOM

Leave it at the default. Without it `3d64000.clock-controller` never probes, the adreno
defers, `msm`'s DRM device fails to bind with `-19`, and the machine boots to a black
screen with no display at all. A config seeded from another machine may not list this
symbol — check for it explicitly rather than assuming.

## 7. Building

`build.sh` builds and installs exactly this configuration. It is idempotent: every step
checks whether its work is already done and skips it, including the source download.
Paths are relative to the script's own directory.

    bash build.sh --check      # read-only: what is done, what would run
    sudo bash build.sh         # do the work

Installing a kernel needs root and writes `/boot/vmlinuz-*`, `/boot/initrd.img-*`, one
DTB, `/lib/modules/<ver>/`, and one boot menu entry. The menu file is backed up before it
is edited.

## 8. Rolling a patch back

A minimal set is one that can shrink. To test whether a patch is still needed, remove it,
rebuild, boot, and check *its* symptom — never a general impression:

    no display         CLK_GLYMUR_GPUCC config   DRM device fails to bind (-19), black screen
    no Bluetooth       serdev client node        no hci_qca device
    no display         the eDP v8 sequence       link training never succeeds
    monitor restarts   combo PHY / xhci / DP     machine restarts on plug-in
    no internal input  the EC group              no i2c 9-0076, no keyboard

If removing a patch does not reproduce its symptom, the patch is unnecessary.

## 9. Diagnostics

The failed boot's own log is the most useful evidence on this machine:

    journalctl --list-boots | tail -8
    sudo journalctl -b -N -k --no-pager | grep -E 'msm_dpu|drm_dp_dpcd_access|dpu_dp_aux|link training|adreno|gmu|glymur-ec' | head -40

Read the boot *before* the current one. Markers worth knowing:

    [drm:adreno_bind [msm]] Found GPU: 44070001                     GPU bound
    [drm:msm_dp_ctrl_link_train_1_2 [msm]] link training #1 ... successful
    msm_dpu: adev bound af54000.displayport-controller              DP controller bound
    msm_dpu: adev bind failed: -19                                  DRM device died

Filter out `vblank` and `timestamp`, or a drm.debug boot buries the signal in hundreds of
thousands of lines.

## 10. Method notes

* Ask "did upstream change this?" by diffing **pristine against pristine**. A diff
  between a patched and an unpatched file is never empty and answers nothing.
* Never test a patch against a tree you have already patched — it will report your own
  work as upstream's.
* Reading files out of a tarball one at a time re-decompresses the whole archive each
  time. Extract once, then diff.
* An empty grep is not evidence of absence: confirm the file was actually there. Two
  intermediate conclusions in this work were wrong for exactly that reason.
* Never `make clean` the tree you are working in; reclaim disk by removing other trees.
  `clean` drops objects; **`mrproper`** also drops the config-generated headers and `.config`,
  so it is the verb an `O=` build demands — save the config aside and restore it afterwards.
* **A freshly extracted tree is already clean.** Extract a new snapshot rather than fighting a
  tree that has been built in and hand-edited: it removes the `mrproper` dance entirely and
  makes the baseline trustworthy again.
* An `O=` build refuses a tree that has ever been built in-tree ("The source tree is not clean").
  Building in-tree from a fresh extract is simpler and is what the build script does.
* `curl` is not installed on this machine. Use `wget`.

---

## 11. Bluetooth: the enable line (0005 + 0006)

Measured on `-edp1-bt` (upstream + 0001 + 0005), 2026-10-03:

    Bluetooth: hci0: setting up wcn7850                  the DT node bound, hci_qca ran
    Bluetooth: hci0: command 0xfc00 tx timeout           the chip never answers
    Bluetooth: hci0: Reading QCA version information failed (-110)
    rfkill: soft=no hard=no                              not blocked
    /lib/firmware/qca/apbtfw11.tlv.zst, apnv11.bin.zst   firmware present

So 0005 was necessary but not sufficient: the device exists, is unblocked, has firmware,
and cannot be enabled. `hci_qca` requires an enable GPIO --

    drivers/bluetooth/hci_qca.c:2457
        if (!device_property_present(&serdev->dev, "enable-gpios")) { ... }

-- and the node carried only the six supplies. The line is pin 116, already described in
this DTS as the Wi-Fi connector's `w-disable2-gpios` (ACTIVE_LOW), and the Glymur
reference board drives the same pin as an enable:

    glymur-crd.dtsi:299   bt-enable-gpios = <&tlmm 116 GPIO_ACTIVE_HIGH>;

0006 adds, to the Bluetooth node:

    enable-gpios    = <&tlmm 116 GPIO_ACTIVE_HIGH>;   what hci_qca looks for
    bt-enable-gpios = <&tlmm 116 GPIO_ACTIVE_HIGH>;   the qcom DTS convention

Both are set because the driver checks one name and the DT convention uses the other;
the extra property is inert. `-edp1-bt` has no EC driver, so the lid switch and power
button are absent there -- the lid cannot test suspend, and `systemctl suspend` is the
way to trigger it instead.

### The set after this, each verdict earned by test

    0001 eDP v8 sequence      KEEP     stock: no panel -> -edp1: panel at 2880x1800
    0003 HBR3 force           RETIRED  panel works without it
    0002 0004 EC driver/node  RETIRED  keyboard and trackpad work without them
    0005 BT serdev node       KEEP     required for hci0 to exist at all
    0006 BT enable GPIO       NEW      only untested change; requires enable-gpios
    CLK_GLYMUR_GPUCC          not a patch -- upstream's own default

---

## 12. External display: dual monitors working (2026-10-03)

Result: **dual monitor works.** Built as `-mon1` on top of 0001/0005/0006.

Patches that achieved it, applied as one set (they interlock -- the combo PHY and its
PCS/lttpr companions were written together, and half a set behaves worse than none):

    0008-qmp-combo-glymur-v5-for-next-20260914      the Type-C/DP combo PHY
    0010-qmp-v8-refresh-pcs-drive-on-training       its PCS side
    0011-msm-dp-lttpr-segment-training              link-training helper
    0012-dp-external-rate-cap                       caps the external DP link rate
    0013-dpu-drop-stuck-flush                       DPU flush drop

Not needed, on this evidence:

    0009-dp-external-rate-and-failed-enable-guard   the "prime suspect" -- the machine no
      longer reboots on plug-in without it. It also cannot be applied after 0012: both
      edit dp_panel.c around line 196, so 0012's hunk wins and 0009 rejects. If it is ever
      wanted, it must go in BEFORE 0012.

    0007-xhci-plat-a16-skip-unsuspended-hcd         applied but produced broken C
      ("missing terminating \" character", xhci-plat.c:563) because upstream has moved that
      file and patch(1) landed it with fuzz instead of failing cleanly. Reverted. If it is
      ever wanted it needs a real rebase, not --forward.

### Why the crash happened at all

Worth recording: plugging in a monitor **rebooted the machine** before this set, every time.
That is a hard crash, not a display failure, and it is why the patches were tested as a set
rather than one at a time -- each individual failure cost a reboot.

### The set now, every verdict earned by test

    0001 eDP v8 sequence        KEEP      stock: no panel -> panel at 2880x1800
    0003 HBR3 force             RETIRED   panel works without it
    0002 0004 EC driver/node    ON HOLD   input works without them; lid/power button untested
    0005 BT serdev node         KEEP      required for hci0 to exist
    0006 BT enable GPIO         KEEP      pin 116; the radio would not answer without it
    0007 xhci-plat              REVERTED  broken against this release
    0008 0010 0011 0012 0013    KEEP      dual monitor works with this set
    0009 failed-enable guard    NOT USED  ordering conflict with 0012; unproven
    CLK_GLYMUR_GPUCC            not a patch -- upstream's own default

---

## 13. The monitor patch set breaks suspend (measured 2026-10-03)

Same upstream release, same eDP and Bluetooth patches, one difference: the combo PHY set.

    -mon1  (0008 0010 0011 0012 0013)   suspend 17:29:11 -> 17:29:50 (aborted at 1 s)
        phy phy-fde000.phy.9: phy init failed --> -110
          qmp_combo_usb_init+0xc4/0xd0 [phy_qcom_qmp_combo]
          dwc3_core_init_for_resume -> dwc3_resume_common -> dwc3_pm_resume
                                  -> dwc3_qcom_pm_resume -> returns -110
        dwc3-qcom a800000.usb: PM: failed to resume: error -110

    -ab1   (no monitor patches)         suspend 17:45:13 -> 17:45:32, clean
        no phy init failure, no dwc3 resume error

So the combo PHY set is unsafe for suspend: `qmp_combo_usb_init()` times out re-initialising
the PHY's USB side on resume, and because that is a device PM callback failing, the whole
system suspend is aborted -- the machine never sleeps and logind retries.

This is the same failure mode the retired 0007 patch documents for xhci-plat (a USB
controller's PM callback failing and aborting system suspend, with logind retrying every
~33 s). There is now a second instance of it, in the combo PHY, and this one is attributable
to our patch set rather than to upstream.

Where to look when fixing it: `qmp_combo_usb_init()` calls `qmp_combo_com_init(qmp, false)`
then `qmp_combo_usb_power_on(phy)`. The v5 patch rewrites init tables and sequences in that
driver for the DP side; the USB side goes through the same COM block, so a resume is the
first time those sequences are replayed against a controller that was never fully torn down.

Until that is fixed, the two configurations trade against each other and both are on disk:

    -mon1   dual monitor works, suspend aborts (PHY resume -110)
    -ab1    suspend runs clean, no external display

### 13a. Correction: the A/B in section 13 did not run

Section 13 claims the monitor patch set causes the resume failure. **That conclusion is
withdrawn -- it compared two boots of the same kernel.**

    17:29  boot bcc60a1f   7.3.0-rc5-next-20261002-mon1   suspend aborted, phy fde000 -110
    17:45  boot fe4f5e00   7.3.0-rc5-next-20261002-mon1   suspend clean, 19 s, no phy error

Same kernel, same boot of the day, opposite results. The comparison that section 13 intended
required rebooting into -ab1 first, and that never happened -- -ab1 was built and installed
but not booted. The two builds were assumed to be the variable; they were not.

What the evidence actually says: on this kernel, one suspend attempt failed with the combo
PHY's USB-side resume timing out, and another completed without it. So the failure is
intermittent or state-dependent rather than attributable to the patch set.

The hypothesis worth testing next, and it fits the chronology: **the failure correlates with
the external monitor having been in use in that boot.** The 17:29 attempt came after a session
of dual-monitor work, and the 17:45 attempt did not. If the combo PHY is in (or has been in)
DP mode, its USB side may be the part that fails to re-initialise.

Test: suspend with an external display attached, and suspend with none, on the same kernel.
That is a within-boot comparison, so it does not need a reboot -- which is exactly the mistake
this section corrects.

---

## 14. What actually fixed suspend, and what the EC was for (2026-10-03, verified)

Two separate faults, and only the second was visible until the first was removed.

**Fault 1 -- the abort.** Every suspend was vetoed by a USB host controller:

    xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
    PM: Some devices failed to suspend, or early wake event detected

-22 is -EINVAL from xhci_suspend(): the USB core leaves hcd->state != HC_STATE_SUSPENDED,
which is true for the first suspend of a boot and false for every one after it. Because the
device callback failed, the whole system suspend aborted -- which is why every attempt
returned in about a second and why the fans and keyboard stayed lit. Fixed by 0007, whose
guard logs the state and returns 0 instead of failing. Verified live:

    first suspend   A16 suspend: hcd state=4  -> normal path, xhci_suspend() returned 0
    second suspend  A16 suspend: hcd state=1  -> guard fired, suspend proceeded anyway

**Fault 2 -- nothing told the EC.** With 0007 in, the suspend completed, but the fans ran on.
They did so because the EC had no driver: no software was telling the controller that the
system was going to sleep, so it held its last fan setting. Adding 0002 + 0004 made the EC
bind at last:

    /sys/bus/i2c/devices/9-0076/driver -> /sys/bus/i2c/drivers/asus-glymur-ec
    hwmon4 asus_glymur_ec: fan1_input, fan2_input, temp1 CPU, temp2 SoC
    leds/asus::kbd_backlight, wakeup: enabled

**Measured result** (boottime - monotonic grows only while suspended):

    before suspend  0 s        fan1_input 2040
    after  suspend  18.5 s     fan1_input 0

**Method notes earned the hard way:**

- Grep for the failure, not for the failure you expect. `failed to suspend async` was in the
  log the whole time; the searches were for `phy init failed` and `dwc3` and missed it. A
  "clean" suspend is not a suspend that worked -- check for the veto lines explicitly.
- The physical signals that were used as evidence, fans and keyboard backlight, are BOTH
  EC outputs. With no EC driver they said nothing about whether the SoC slept. Use
  boottime-minus-monotonic instead.
- `0008`/`0010` are not "monitor patches". The internal panel is an aux-bus panel on
  displayport-controller@af6c000, so the panel's bring-up needs the combo PHY's DP side.
  Removing them to make a "minimal sleep test" produced a black screen, and the earlier
  claim that 0001 alone brings the panel up was only true while the tree still carried
  content from the September tree.
- Reverting with `patch -R` is as unreliable as applying with `--forward`. Restoring the
  file from a pristine copy is the dependable revert -- which is why one extraction of the
  release you are building is worth keeping on disk.
- A non-raw Python string turns `\n` into a real newline inside a C literal and breaks the
  build at the same line every time. Gate the build on a split-literal check.

**The port set, verified on hardware in one kernel:**

    0001 phy-qcom-edp v8 sequence      panel
    0002 dts EC node, 0004 EC driver   fans stop on suspend, fan/temp readings, kbd LED, wakeup
    0005 BT serdev node, 0006 bt-enable-gpio pin 116   Bluetooth
    0007 xhci-plat skip-unsuspended-hcd               suspend no longer aborts
    0008 0010 0011 0012 0013           panel bring-up + external monitor
