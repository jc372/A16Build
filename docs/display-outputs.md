# External displays — USB-C / DP alt-mode, HDMI

**State: both external outputs work (2026-10-02 evening) — when the attach trains.** A failed attach still costs the external picture; and until item 11 it also cost the desktop. `sudo bash ~/a16.sh display evict` now takes a wedged output out of the compositor's view without unplugging it. The Gigabyte trains over USB-C DP on
either port at 5.4 Gbps (`a16_dp_max_rate=540000`, persistent) - hotplug included, no freezes - and
the MSI runs on **HDMI** at 5120x1440. Every earlier failure was the external link being asked for
8.1 Gbps when the sinks only guarantee 5.4 Gbps, plus the MSI's own DP repeater, which fails channel
equalization at any rate and used to take the desktop down with it. See item 10 below for the exact
artifacts, and `BRINGUP/evidence/2026-10-02-msi-over-hdmi-and-gigabyte-both-ports.txt`.

## The pieces

| | |
|---|---|
| DP controllers | `af54000`, `af5c000`, `af64000` displayport-controllers (three) plus the panel's `af6c000` |
| Connectors | `card1-DP-1`, `card1-DP-2`, `card1-HDMI-A-1` |
| Combo PHYs | `fd5000.phy` (→ `af54000`), `fde000.phy` (→ `af5c000`), `88e1000.phy` (→ `af64000`, the tert PHY) |
| Alt-mode plumbing | `pmic_glink` + `typec`/`ucsi_glink` + `phy-qcom-qmp-combo` |
| HDMI | the tert PHY's DP lanes into `hdmi-bridge` (`parade,ps185hdm`) — not a separate HDMI controller |

Each external DP controller takes its link clock from its combo PHY:
`assigned-clock-parents = <&phy… QMP_USB43DP_DP_LINK_CLK>` in the machine's DT, so the DP output
cannot come up before the PHY does.


## Monitors tested

| Monitor | Identity | USB-C DP | HDMI |
|---|---|---|---|
| **Gigabyte** (3440x1440 21:9) | hub + PD; its hub presents a Realtek `0bda:0329` card reader | **works on either port** at `LINK_BW_SET 0x14` (5.4 Gbps x4) when the attach trains: LTTPR segment `#1` *and* `#2` plus the sink segment all train, hotplug re-trains cleanly, 0 prepare failures, 0 DPU timeouts. One later DP-2 attach failed LTTPR training (`ret=-110`) *with* the cap active — made while the machine was idle with the screen off; see item 11 | not exercised |
| **MSI** (5120x1440 / 3840x1080, 32:9 dual-panel) | VIA Labs hub `2109:2211`, `1462:3fa4` controller, `MSI Optix Driver` storage device, PD; DPCD advertises an internal repeater (`0xf0000` = `20 1e 80 55 …`) | **fails at every rate**: DP-1 and DP-2, at 8.1 Gbps and at 5.4 Gbps, all end in that repeater's channel equalization timing out (`ret=-110` → `rc=-104` → `DP display prepare failed`) | **works** - `card1-HDMI-A-1 connected/enabled` at 5120x1440 with no DPU errors, because the HDMI output is the tertiary PHY into `hdmi-bridge` and does not pass through the monitor's DP repeater |

Both monitors bring a USB hub and a PD cord, so neither is what decides success: the Gigabyte fails
on nothing and the MSI fails only where its repeater sits in the path. Both advertise the same DPCD
shape - 5.4 Gbps in the basic receiver capability block (`0x00001 = 0x14`) and 8.1 Gbps in the DPRX
extended receiver capability block (`0x02200` byte1 = `0x1e`) that `drm_dp_read_dpcd_caps()` merges
over the basic one.


## Current state

    qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier fd5000.phy
        for /pmic-glink/connector@0          (and fde000.phy for connector@1)

The device-link failure is the USB-C alt-mode connector not being able to bind to its combo PHY.
This is about the **external** path only: the internal panel's PHY is `faac00.phy`, a different
driver (`phy-qcom-edp`), and it is unaffected.

The clock side is settled and is the same on both external outputs — the PHY cannot turn on the clock
the display controller needs, so the controller's enable returns `-16` (`-EBUSY`):

| Output | Clock that comes up stuck | Where it is raised |
|---|---|---|
| HDMI (`88e1000.phy` → `hdmi-bridge`) | `gcc_usb3_tert_phy_com_aux_clk status stuck at 'off'` | `qmp_combo_com_init` → `qmp_combo_dp_init` → `phy_init` → `msm_dp_ctrl_phy_init`, from the fbdev client's connector probe at **every boot**, with nothing plugged in |
| USB-C DP alt-mode (`card1-DP-2` ← `af5c000` ← `fde000.phy`) | `disp_cc_mdss_dptx1_link_clk status stuck at 'off'` | `msm_dp_ctrl_enable_mainlink_clocks` → `msm_dp_display_atomic_enable`, during the atomic commit that would enable the output |
| USB-C DP alt-mode (`card1-DP-1` during 2026-10-02 test; `af54000`) | `disp_cc_mdss_dptx0_link_clk status stuck at 'off'` | Captured at hotplug in `BRINGUP/evidence/2026-10-02-usbc-dp1-warn-reboot.txt`; call trace enters `msm_dp_ctrl_enable_mainlink_clocks` → `msm_dp_display_atomic_enable` |

Both are `clk-branch.c:87` (`clk_branch_wait` → `-EBUSY`) from the QMP combo PHY's clock bundle, and
the HDMI one is reproducible on every boot, so it needs no monitor to study. `qmp_combo_com_init`
enables its clocks second (`reset_control_bulk_deassert` succeeds, `clk_bulk_prepare_enable` is what
fails: `Failed to enable clk 'com_aux': -16`), the PHY's `power-domains` is `GCC_USB_2_PHY_GDSC`, and
every later `phy_power_on was called before phy_init` on that PHY is a consequence of the failed init.

What the boot log and the live clock tree already rule out (2026-09-17, capture in
`~/a16-payload/display-outputs-20260917-110714.log`):

- **Not the power domain.** `gcc_usb_2_phy_gdsc` reads `on`.
- **Not a missing clock reference.** `devm_clk_bulk_get_all` takes the DT order — aux, ref, com_aux,
  usb3_pipe — and `clk_bulk_enable` stops at the first failure and reports its name
  (`drivers/clk/clk-bulk.c`). The name reported is `com_aux`, so `aux` and the TCSR clkref `ref` were
  enabled successfully one and two steps earlier.
- **Not a structural difference from the working PHY.** The three combo PHYs have identical
  `clock-names`, the sec PHY (`fde000.phy`) works with the same driver, the same ordering and the same
  table shape; the tert table is the sec table shifted one bank (`0xe1070/74/78` vs `0xe2070/74/78`).

That leaves the `com_aux` branch itself, between `aux` (which asserts) and `pipe` (which is never
halt-checked), with `gcc_usb_2_phy_gdsc` on and its ref on.

**Measured 2026-09-17** (`~/a16-payload/phy-clock-20260917-111316.log`, from
`BRINGUP/tools/a16-phy-clock-test.sh read`): the tert `com_aux` CBCR at `0x1e1074` holds
`0x88000001` — enable bit set, halt bit *still* set — while its working sec twin at `0x1e2074` holds
`0x08000001`, identical except for the halt bit. The tert `aux` branch at `0x1e1070` asserts fine, and
it shares the parent RCG (`gcc_usb3_tert_phy_aux_clk_src`), the `enable_mask` and the `BRANCH_HALT`
check. So the address is right, the clock table is innocent, and the hardware is holding this one clock
off. `clk_summary`'s `Y` on that clock is consistent, not contradictory: `clk_branch2_ops.is_enabled`
is `clk_is_enabled_regmap`, i.e. the enable bit, and the failed bulk enable never unwound `com_aux`
(`clk_bulk_enable` disables only the clocks before the one that failed).

What is left is upstream of the branch. Two things the software can do on its own were checked and are
in place, so they are not the explanation: this generation's cfg uses `qmp_phy_vreg_refgen`, i.e. the
`refgen` rail *is* requested (only the glymur/hawi cfgs do that), and `clk_bulk_enable` reporting
`com_aux` means `aux` and the TCSR reference were enabled first.

The userspace poke that would have settled it is not available either: `/dev/mem` *reads* work, but a
write mapping is refused with `EINVAL`, because this kernel is built with `CONFIG_STRICT_DEVMEM=y`, and
the clock framework's per-clock `clk_prepare_enable` knob is compiled out (`#ifdef
CLOCK_ALLOW_WRITE_DEBUGFS` in `drivers/clk/clk.c`). `phyclock read` still prints the registers, the TCSR
words and the rails; `phyclock cycle` reports that it cannot write and changes nothing.

The one thing that is demonstrably **off** is the instance's controller domain:

    gcc_usb30_tert_gdsc  off      gcc_usb30_sec_gdsc  on      gcc_usb30_prim_gdsc  on     gcc_usb30_mp_gdsc  on

The register layout puts the COM block in it: GDSCR `0xe1010`, CBCRs `0xe1070/74/78` and the RCG
`0xe1080` are one page, the same shape as the working sec instance at `0xe2010/70/74/78/80`. A domain is
powered by its DT consumer, and the only consumer of `GCC_USB30_TERT_GDSC` is the tertiary USB3
controller `usb@a000000`, which this machine's DTB leaves `disabled` — the board has no USB port on that
PHY, it feeds the HDMI bridge — while the other three instances are `okay` and their domains are on.

That is not conclusive: the DTB the firmware ships has `usb@a000000` disabled as well, so either the
firmware's power driver votes that domain without a DT consumer (which a DT-driven Linux cannot) or the
domain is not the blocker. `BRINGUP/tools/a16-tert-phy-power.sh` (`sudo bash ~/a16.sh tertphy arm`, then
`check` after the reboot, `revert` to undo) tests exactly that: with the controller enabled its domain
is requested, so `gcc_usb30_tert_gdsc` should come up — and if the COM clock was only unpowered, it comes
up with it and the PHY init stops failing.





**Historical note (2026-09-17):** the qmp combo PHY needed a Glymur-specific programming series,
which was posted but not in this kernel snapshot. A v5-derived candidate has since been built and
hardware-tested: it reached LTTPR training on DP-1, but video did not appear; see the dated result
and next-candidate analysis below. Do not treat this old note as a current stop-work verdict.

## Plugging a monitor in

Verified 2026-09-17 with an MSI monitor on the USB-C port (evidence:
`BRINGUP/evidence/2026-09-17-external-display-freeze.txt`, tool: `BRINGUP/tools/a16-display-outputs.sh`).
A USB mouse and keyboard on the same port are unaffected; it is the display path that fails.

1. The monitor's hub enumerates (`2109:2211` VIA Labs, then the monitor's own `1462:3fa4` device plus a
   `usb-storage` interface whose reads error out), and `ucsi_glink` reports the partner's alt-mode list
   as malformed — 29 × `duplicate partner altmode SVID 0xff01` (VESA DisplayPort) on `con2`.
   The DP-2 connector does read an EDID (48–144 Hz), so AUX and the sink are reachable.
2. The commit that enables DP-2 fails at `disp_cc_mdss_dptx1_link_clk` (table above):
   `Unable to start link clocks. ret=-16` → `DP display prepare failed, rc=-16`.
3. **That failed commit never completes**: `[dpu error]vblank timeout: 80821300`,
   `[dpu error]wait for commit done returned -110` (`-ETIMEDOUT`), `[dpu error]enc38 frame done
   timeout`, repeating for as long as the compositor keeps trying. `msm` carries on through the
   encoder enable instead of failing the commit cleanly, so the interface is left enabled with no
   clock behind it and no vblank ever arrives.
4. gnome-shell's KMS thread then blocks in `DRM_IOCTL_WAIT_VBLANK` forever: the picture is frozen.

**The kernel is not frozen.** In that boot, `logind` still serviced the power key 37 s after the last
`[dpu error]`, `/var/crash` is empty and kdump captured no vmcore (nothing panicked). The desktop can
be reached over SSH (`sshd`, Wi-Fi), and `sudo bash ~/a16.sh display recover` restarts gdm once the
monitor is unplugged. This also means a fresh capture does not need a working screen:
`sudo bash ~/a16.sh display watch` over SSH, then plug the monitor in.

One costing detail: that boot ran the `drm.debug=0x1ff` debug entry, whose `DRM_UT_CORE` ioctl logging
wrote 7.6 M lines in 90 minutes; journald then dropped kernel messages (`Missed N kernel messages`),
so part of the pre-freeze record is gone. `sudo bash ~/a16.sh display arm` sets `drm.debug=0x1fe`,
which keeps KMS/ATOMIC/VBL/DP and drops exactly that ioctl tracing.


## The patch we carry for the *internal* DP path

This one matters even though it is not about external displays: on Glymur, a **failed** eDP enable
followed by any disable path (DPMS off, a modeset) makes TrustZone force-stop SOCCP/ADSP and the SoC
resets silently ~50 ms later — which presents as "the machine just died". It is posted and not
merged. It matters when an eDP enable fails and a disable path follows.

<!-- include: patches/0008-drm-msm-dp-skip-push-idle-when-link-never-enabled.patch -->

<!-- BEGIN include: patches/0008-drm-msm-dp-skip-push-idle-when-link-never-enabled.patch (generated by scripts/render-docs.py -- do not edit by hand) -->

```diff
From: Jesse Casco <jesse.casco@gmail.com>
Subject: [PATCH] drm/msm/dp: skip PUSH_IDLE when the link was never enabled
Date: Sat, 08 Aug 2026 13:13:41 -0400
Message-ID: <20260808171325.133041-1-jesse.casco@gmail.com>
State:       posted, not merged (not in mainline or linux-next at the time of writing)
Tested-by:   ASUS Zenbook A16 (UX3607OA) on next-20260803 / next-20260807 (the reporter's machine)
Why we want it: on glymur, a failed eDP enable followed by any disable path (DPMS off,
             session exit, `echo 1 > /sys/class/graphics/fb0/blank`) makes TrustZone
             force-stop SOCCP/ADSP and the SoC resets silently ~50 ms later.
Not needed once the eDP link trains (which BRINGUP/patches/0006+0007 make it do); it is
insurance for a boot where training still fails.
Provenance:  verbatim from https://patchew.org/linux/20260808171325.133041-1-jesse.casco@gmail.com/

diff --git a/drivers/gpu/drm/msm/dp/dp_display.c b/drivers/gpu/drm/msm/dp/dp_display.c
index bc646d172..5d2ddf180 100644
--- a/drivers/gpu/drm/msm/dp/dp_display.c
+++ b/drivers/gpu/drm/msm/dp/dp_display.c
@@ -1458,6 +1458,20 @@ void msm_dp_display_atomic_disable(struct msm_dp *dp)
 
 	msm_dp_display = container_of(dp, struct msm_dp_display_private, msm_dp_display);
 
+	/*
+	 * If .atomic_enable() bailed out - link training failure is the common
+	 * case - the mainlink was never brought up and ->power_on stayed false.
+	 * Driving the PUSH_IDLE pattern into a controller that was never
+	 * enabled times out, and .atomic_post_disable() then drops the
+	 * controller's runtime-PM reference without tearing the PHY back down,
+	 * because msm_dp_display_disable() returns early on !power_on.  On
+	 * glymur (Snapdragon X2 Elite) that combination is answered by a
+	 * TrustZone-level SOCCP/ADSP force-stop and a silent SoC reset.
+	 * There is nothing to push idle, so leave it alone.
+	 */
+	if (!dp->power_on)
+		return;
+
 	msm_dp_ctrl_push_idle(msm_dp_display->ctrl);
 }
 
-- 
2.55.0
```

<!-- END include: patches/0008-drm-msm-dp-skip-push-idle-when-link-never-enabled.patch -->
Applying it means rebuilding `msm.ko` — see [build.md](build.md), and note that the module must be
rebuilt with a config that matches the kernel, including the ABI verification step.

## Verify

    bash ~/A16Build/BRINGUP/tools/a16-display-outputs.sh          # or: sudo bash ~/a16.sh display
    ls /sys/class/drm/                              # card1-DP-1, card1-DP-2, card1-HDMI-A-1
    cat /sys/class/drm/card1-DP-1/status            # disconnected until the combo PHY work lands
    journalctl -k -b 0 -o cat | grep -iE 'altmode|ucsi|qmp|combo' | tail

## Watch capture

`sudo bash ~/a16.sh display watch` now writes connector snapshots to the printed state-log path and
streams new kernel-ring messages independently to a companion `*.kernel.log` file (raw monotonic
timestamps from `dmesg --follow-new`). A separate sync loop flushes that kernel log every two seconds,
even while a large state snapshot is running. The watcher can run in a local terminal; SSH is optional.
Stop normally with Ctrl-C. If the machine resets, the companion kernel log is the first file to inspect.

For each test, note both paths printed at startup. Do not treat EDID detection as proof that video is
active: check the output's `enabled` state as well as the live DP/PHY logs.

## What has to happen for this to work

1. ~~Find why the PHY's clock bundle is refused~~ — **answered 2026-09-17**: the COM clock was only
   unpowered. Its page belongs to `GCC_USB30_TERT_GDSC` (GDSCR `0xe1010`, CBCRs `0xe1070/74/78`, RCG
   `0xe1080`), whose only DT consumer is `usb@a000000` — disabled on this board, and when enabled it
   defers on this very PHY, so it never votes. Giving the domain a consumer that always binds
   (`/hdmi-bridge`, exactly one `power-domains` specifier) powers it at attach and the boot comes
   back clean. Tools: `sudo bash ~/a16.sh tertphy arm bridge` / `check` / `revert`; evidence:
   `BRINGUP/evidence/2026-09-17-tertphy-domain-check.txt`. The proper form of the fix is a
   machine-DTS change.
2. **The external path had been exercised but did not yet produce a picture at this point (superseded — the outcome is item 10).** Earlier 2026-10-02 USB-C hotplugs registered DP-1/DP-2 and read modes, but outputs stayed `enabled=disabled`; the DP-1 failure showed DPTX0's link clock stuck off and `ctrl_link` enable `-16`. A v5-derived QMP combo-PHY candidate was staged and loaded (vermagic and all 81 imported CRCs match stock). During the 13:50 test, the capture reached DP link training #2 on PHY 1, then LTTPR training failed with `ret=-110`; DP prepare failed with `rc=-104`. Unlike the earlier failure, this capture did not log the DPTX0 clock-stuck / `ctrl_link -16` errors. A hard reboot followed; the preceding boot journal ends after the DP AUX error, without identifying the reset initiator or proving causality. The earlier QMP-only trial was reverted and a following boot loaded stock; that is historical, since a combined candidate is now staged below. **Keep the monitor unplugged until the training failure is analyzed.** Evidence: `BRINGUP/evidence/2026-10-02-qmp-combo-v5-test-hard-reboot.txt` and the earlier DP captures listed above. The watcher writes kernel messages to an independent, periodically synced sidecar. The build and candidate source diff are documented in `BRINGUP/evidence/2026-10-02-qmp-combo-v5-build.txt` and `retired/patches/old-numbering/0015-qmp-combo-glymur-v5-for-next-20260914.patch`. Code review identified a possible remaining LN0/LN1 drive-level limitation, so link training was not guaranteed.
3. **Combined candidate tested: no reboot, but LTTPR EQ failed (2026-10-02).** Source review found the local A16 eDP rate workaround in `dp_panel.c` was unconditionally forcing HBR3 (8.1 Gb/s) on *all* external DP/HDMI links whenever the DT allowed it, even if the sink or its LTTPR advertised a lower rate. This is a concrete bug and a plausible explanation for channel-equalization failure; the failed attempt's exact rate was not captured (`drm.debug=0`). `phy 1` in that log means `DP_PHY_LTTPR1`, the first DP repeater, **not** the second physical QMP PHY. The new MSM candidate restricts that override to eDP and adds the posted A16-tested guard against PUSH_IDLE after failed enable (`patches/0008-drm-msm-dp-skip-push-idle-when-link-never-enabled.patch`); the guard addresses a known reset-prone path but this USB-C reboot's cause is still unproven. The prior QMP v5 candidate is reused unchanged. The MSM module builds and matches 805/805 imported CRCs. Details: `BRINGUP/evidence/2026-10-02-dp-next-candidate.txt`, source delta: `retired/patches/old-numbering/0016-dp-external-rate-and-failed-enable-guard.patch`. `bash ~/a16.sh dpnext dry-run` passed; the operator then ran `sudo bash ~/a16.sh dpnext` at 14:52 and it reported both modules and initrd entries verified with rollback state. The operator tested it: DP-1 became connected/enabled but no picture, the internal panel blacked out, and unplugging USB-C restored the laptop screen without reboot or GDM restart. DP-only logs confirm 8.1 Gbps/4 lanes, successful LTTPR1 clock recovery, and EQ requesting pre-emphasis 1→2→3 without convergence; the scoped eDP-rate change did not lower this monitor's supported rate. `display watch dp` was stopped and DRM debug restored to 0. Do not repeat the same hotplug. See `BRINGUP/evidence/2026-10-02-dp-next-black-panel-no-reboot.txt`; next investigate dynamic PCS LN0/LN1 drive-level programming during `set_voltages`.
4. **PCS refresh trial did not fix LTTPR EQ; hard-reset report (2026-10-02).** The previously BUILT candidate was staged and booted. It logged the intended PCS sequence `0x02→0x12→0x16→0x1a` at 8.1 Gbps, but LTTPR1 phase #2 still returned `-110`; main-link training failed, then DPU vblank/commit/frame-done timeouts continued. Operator reports that the laptop panel initially stayed usable, the external display appeared briefly then said no video, and opening Display Settings froze the machine, requiring hard reboot. The reboot's initiator is unknown; this was not captured with a dedicated `display watch dp` log. This experiment demonstrates that refreshing PCS drive levels alone was insufficient on this link; it does not show whether that change contributed to the later freeze. The running boot still has QMP `37880928124460B5D4B8E91`, MSM `BBD010BD47287F02B65EE84`; root-only dpdrive and parent rollback states remain present. **Do not reconnect the monitor on this candidate.** First revert only the added layer: `sudo bash ~/a16.sh dpdrive revert`, then reboot; only afterward consider `dpnext revert` if returning to stock. Full evidence: `BRINGUP/evidence/2026-10-02-dpdrive-test-hard-reboot.txt`. Next diagnostic work should investigate LTTPR pattern/capability behavior or a distinct lower-rate test, not stack another change or repeat the same hotplug.

5. **One intermittent successful USB-C picture after quick replug (2026-10-02); no trace.** The operator reports that after `dpdrive revert` restored the prior QMP v5 module/initrd (verified 16:10:15), unplugging and reconnecting USB-C quickly before the internal panel flashed/resized made the external monitor display video once. It was not repeatable; later attempts were followed by hard resets or black-screen boots. At the latest verified check, QMP v5 `151CA3C3BDC39CA185C951B` and MSM `BBD010BD47287F02B65EE84` were loaded, with `dpdrive` state absent. The brief success cannot be assigned to a specific mode or training sequence because no watcher was running. Reconnect timing is a new clue, not a proven fix. There is no evidence that Snapdragon-specific residual software state needs clearing; UCSI did log repeated duplicate partner-altmode SVID `0xff01` warnings in a later failed boot, but no causal link is established. Preserve the current boot and prepare a watcher-first capture before another connection; don't keep forcing modes in Display Settings. Details: `BRINGUP/evidence/2026-10-02-intermittent-usbc-video-after-fast-replug.txt`.
6. **Repeated DP-2 hotplug was captured; freeze/reboot followed (2026-10-02).** The watcher recorded four DP-2 connect/disconnect cycles; DP-1 and HDMI remained disconnected. DP-2 is the `af5c000` controller fed by `fde000.phy`, different from the earlier DP-1 route (`af54000`/`fd5000.phy`). It advertised 5120x1440/3840x1080 and read `enabled`, but there was no visible picture. The kernel log selected 8.1 Gbps ×4; LTTPR1 clock recovery passed and EQ failed `-110`, then the controller recorded downstream `phy 0` training phases successful and began stream setup. DPU vblank/commit/frame-done/IRQ timeouts followed almost immediately; another LTTPR1 training attempt failed. The watcher sidecar ends around 16:34:32 with repeated DPU timeouts. Boot changed from `42967b08-f757-4e86-b128-936f6ae93c28` to `4d9da362-0252-4f40-a2ff-7fd41cdb8aad`; reset cause unknown. At the verified post-reboot check, QMP v5 `151CA3C3BDC39CA185C951B` and MSM `BBD010BD47287F02B65EE84` were loaded; `dpdrive` was absent. Do not repeat cycles. Preserve the working boot and compare DP-2's controller/PHY path against DP-1 before choosing a new code change. Logs: `/home/jc/a16-payload/display-outputs-20261002-163318.log`, `/home/jc/a16-payload/display-outputs-20261002-163318.kernel.log`; concise evidence: `BRINGUP/evidence/2026-10-02-repeated-hotplug-dp2-freeze.txt`.
7. **LTTPR segment-training fix built, ABI-verified, next test pending (2026-10-02).** Comparing the DP-1 and DP-2 captures shows the repeater segment is consistently trained with **TPS4** while the sink segment is trained with **TPS3** and succeeds. The TPS4 choice comes from `panel->dpcd`, which is sampled while the LTTPRs are still transparent - the monitor reports `DPCD 0x003 = 0x81` (TPS4 bit set) in that state, but `0x01` once the LTTPRs are in non-transparent mode. The driver also never read the repeater's PHY capability register (`0xf0021`), so it drove pre-emphasis 3 into a repeater whose advertised maximum it had never checked; clock recovery collapses right at that point in the DP-2 capture. `retired/patches/old-numbering/0018-msm-dp-lttpr-segment-training.patch` (4 files) limits TPS4 to the sink segment, reads and stores each LTTPR's PHY capabilities at init, clamps the requested voltage-swing/pre-emphasis levels to the advertised maximum, and signals max-reached at the clamp. Built natively with no compiler warnings; 805/805 shared imported-symbol CRCs unchanged and the three new imports cross-checked against in-tree `xe.ko`. `sudo bash ~/a16.sh msmlttpr` stages only msm.ko for the next boot over the dpnext layer, with its own module+initrd rollback; `msmlttpr revert` restores dpnext (run it before `dpnext revert`). Not yet tested on hardware - the DPU vblank/frame-done timeouts seen after a successful sink-segment training are still unexplained and may remain the last blocker. Evidence and exact hashes: `BRINGUP/evidence/2026-10-02-msm-lttpr-segment-candidate.txt`.
8. Then check the `pmic_glink` ↔ combo-PHY device links, which the alt-mode connector creation
   depends on.
9. The currently loaded MSM candidate includes the failed-enable PUSH_IDLE guard from patch 0008. It was tested on
   this A16 for an eDP failure path; whether it prevents the external-path reset is still unproven.
   If link training fails without a reboot, retain the logs and distinguish remaining PHY signal
   levels, LTTPR behavior, and rate selection instead of immediately stacking another patch.

10. **Both external outputs work (2026-10-02 evening) - the requested rate was the whole problem on USB-C, and HDMI sidesteps the MSI's repeater.** The driver was asking for 8.1 Gbps x4 on both USB-C ports because the sinks advertise 8.1 Gbps in the DPRX *extended* receiver capability block (`0x02200`) which `drm_dp_read_dpcd_caps()` merges over the *basic* block (`0x00001 = 0x14` = 5.4 Gbps), and nothing in `msm_dp_panel_read_link_caps()` ever consults the basic value; the retry loop's `msm_dp_ctrl_link_rate_down_shift()` is never reached after an LTTPR-segment failure, so the rate was never lowered. `retired/patches/old-numbering/0019-msm-dp-external-rate-cap-parameter.patch` adds the module parameter `a16_dp_max_rate` (kHz, 0 = off, eDP exempt) and `/etc/modprobe.d/a16-msm-dp-rate.conf` sets it to 540000 persistently (confirmed inside the initramfs, so it reaches the early module load). With it: the Gigabyte trains on **either** port - `link training #1`/`#2` on `phy 1` (the LTTPR segment, whose `#2` channel equalization had failed `ret=-110` in every earlier session) followed by `#1`/`#2` on `phy 0` (the sink) at `LINK_BW_SET 0x14` - hotplug included, with 0 prepare failures and 0 DPU/vblank timeouts; eDP stays exempt and keeps HBR3 (`0x1e`). The MSI's own repeater still fails equalization at every rate, and that failure used to freeze the desktop: its interface has no pixel clock, so the vsync that clears `CTL_FLUSH` never arrives and `dpu_encoder_phys_vid_wait_for_commit_done()` times out on every later commit (one atomic commit covers both CRTCs, so the internal panel stops too, and only a reboot cleared it). `retired/patches/old-numbering/0020-dpu-drop-stuck-flush-after-vblank-timeout.patch` drops that stuck pending flush in the timeout path, so a dead sink no longer blocks the *next* commit (built and live; exercised 2026-10-02 20:53 — it fires as designed but is not sufficient on its own, because every later commit still carries the dead output: see item 11). The MSI now runs over **HDMI** instead: `card1-HDMI-A-1 connected/enabled` at 5120x1440 alongside the internal panel, 0 DPU errors, because the HDMI output is the tertiary combo PHY (`88e1000.phy`, its clock-domain fix in force) into `hdmi-bridge` - the monitor's DP repeater is not in that path. Candidate in use: srcversion `F60D32C034D8487FB39FE42`, sha256 `c90b9d8e313d224b73238998ffb53fb8c152c25513ddc8c91bc296a896554328`, ABI gate PASS (`task_struct.thread_pid` 2144, `module_layout` `0xe6658f7b`; the gate tool is `BRINGUP/tools/a16-abi-layout-gate.sh` and it caught a copied tree whose generated headers were stale, which had produced a 320-byte `task_struct` shift and an oops in `msm_gpu_create_private_vm` - see `BRINGUP/evidence/2026-10-02-msmlttpr-crash-layout-mismatch.txt`). Staged with `sudo bash ~/a16.sh dprate` over the dpnext layer; built by `BRINGUP/tools/a16-build-dp-rate-module.sh`. Open: the HDMI refresh ceiling (5.4 Gbps x4 carries 5120x1440@60, not 120 Hz - raise the parameter to 810000 to test), one HDMI hotplug cycle to exercise patch 0020, and making the rate handling permanent in the driver instead of a module parameter.

11. **A failed attach froze the desktop; evicting the output clears it (2026-10-02 20:53).** Plugging the
    Gigabyte into DP-2 failed LTTPR training — `link training #2 on phy 1 failed. ret=-110`, then
    `LTTPR(s) failed` and `DP display prepare failed rc=-104` — even with `a16_dp_max_rate=540000` in force.
    The DPU then logged **41** `wait for commit done` / `vblank timeout` pairs and the desktop stopped
    updating, with the kernel, SSH and the network all alive. `patches/0020` fired exactly as designed (the
    pending flush is dropped, the timeout is reported, nothing blocks), but it is not sufficient: every
    later atomic commit still *contains* the dead output, so each one times out again, and because one
    commit covers both CRTCs the built-in panel stops updating with it. Unplugging is what clears that
    state; the software equivalent is now a command — `sudo bash ~/a16.sh display evict` forces the
    connector off so DRM reports it disconnected and the compositor drops it, then `display recover`
    rebuilds the desktop (and no longer has to refuse for lack of an unplug). No suspend was involved: the
    dark panel in this incident was the idle blank, not a sleep. Capture:
    `BRINGUP/evidence/2026-10-02-dp2-attach-froze-desktop-ssh-alive.txt`. Open: whether the failure came
    from attaching out of a blanked/idle state (the same monitor and port trained cleanly earlier the same
    evening), and a driver follow-up to `0020` that skips later commits for an encoder whose enable failed.
