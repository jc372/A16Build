# A16 — prioritized remaining work

> Status refreshed 2026-10-02 after the latest staged Glymur PCS-drive candidate did not restore external video and the operator reported a hard reboot; exact reset cause remains unknown. Historical experiment records below are retained; use the latest dated evidence and status table.
>
> Ranking is by likelihood of making safe, measurable progress (easy verification first), not by subsystem importance:
>
> 1. **DONE 2026-10-02 evening: both external outputs work - the Gigabyte over USB-C DP at 5.4 Gbps (either port, hotplug included) and the MSI over HDMI at 5120x1440. Next: make the rate handling permanent and check the HDMI refresh ceiling.**
>    The cap is persistent (`/etc/modprobe.d/a16-msm-dp-rate.conf`, confirmed inside the initramfs), the freeze mitigation (`patches/0020`) is staged and live but unexercised, and the HDMI output is a DP link into the bridge on the tertiary combo PHY, so the same cap applies there - 5.4G covers 5120x1440@60 (~12.6 Gbps of ~17.3 usable), not 120 Hz. Remaining work, in order: (a) `patches/0020`-style permanence for the rate itself - the retry loop has `msm_dp_ctrl_link_rate_down_shift()` but never reaches it after an LTTPR-segment failure, so a failed equalization should down-shift and retrain instead of needing a module parameter; (b) one HDMI hotplug cycle to exercise 0020 and confirm the bridge link re-trains; (c) the refresh ceiling on HDMI - raise `a16_dp_max_rate` to 810000 and re-plug only if a higher mode is wanted; (d) optionally the MSI's own DP repeater for upstream (it fails channel equalization at 8.1G *and* 5.4G, on both ports).
>    `dprate` has been rebuilt with two changes (`patches/0019` rate cap, `patches/0020` drop the stuck DPU flush so a dead sink cannot freeze the desktop) and now installs `a16_dp_max_rate=540000` as a modprobe option so the cap survives reboots. Sequence: `sudo bash ~/a16.sh dprate revert`, reboot to [3], `sudo bash ~/a16.sh dprate`, reboot. Then for HDMI: `sudo bash ~/a16.sh tertphy check` (the tertiary combo PHY's clock-domain fix), `sudo bash ~/a16.sh display watch`, plug HDMI into the MSI, and watch `card1-HDMI-A-1`. The A16's HDMI output is a DP link into an HDMI bridge on that PHY, so the DP rate cap also applies to it - 5.4G covers 4K@60, raise it with `echo 810000 | sudo tee /sys/module/msm/parameters/a16_dp_max_rate` only if a mode needs more. (2026-10-02 evening: two monitors, both ports) The failure is the requested link rate, not the monitor and not the port: only Gigabyte-on-DP-1 worked, and every failure is the LTTPR segment's channel equalization timing out with pre-emphasis already at maximum (`ret=-110` -> `rc=-104` -> `DP display prepare failed`), after which the DPU's commits never complete and the desktop freezes. The monitors' basic DPCD block advertises HBR2 (5.4G) while the DPRX extended block - which `drm_dp_read_dpcd_caps()` merges over it - advertises HBR3 (8.1G), so the driver asks for 8.1G x4 on a link only guaranteed at 5.4G. `patches/0019` adds the module parameter `a16_dp_max_rate` so the rate can be swept live: `sudo bash ~/a16.sh msmlttpr revert` (this layer only), reboot to [3], `sudo bash ~/a16.sh dprate`, reboot with the monitor unplugged, then `echo 540000 | sudo tee /sys/module/msm/parameters/a16_dp_max_rate`, `sudo bash ~/a16.sh display watch dp`, connect **once**; try 270000 if 540000 also fails. Revert with `dprate revert`. Evidence: `evidence/2026-10-02-gigabyte-vs-msi-port-pattern.txt`. History for this item:
>    Added 2026-10-02: the staged module had been built by hand in a copied tree whose
>    `include/generated/autoconf.h` was stale (no `CONFIG_DEBUG_INFO_BTF`/`CONFIG_SCHED_CLASS_EXT`), so it
>    read `task_struct.thread_pid` at byte 1824 instead of 2144 and oopsed in `msm_gpu_create_private_vm`
>    on three boots - the GPU fault had nothing to do with the displayport change. It is rebuilt on a
>    config-synced tree with the ABI verified field by field (`BRINGUP/tools/a16-abi-layout-gate.sh`,
>    sha256 `79bd07cc…`). Run that gate before staging any module, and revert the currently installed bad
>    module first: `sudo bash ~/a16.sh msmlttpr revert`. Reading the two captures together localizes the repeater failure: the LTTPR segment was trained with TPS4 taken from the pre-LTTPR (transparent-mode) `panel->dpcd` snapshot (`0x003 = 0x81`), while the same byte reads `0x01` once the LTTPRs are active - and TPS3 is what the sink segment trains with successfully in the same logs. Drive levels were also never clamped to the repeater's advertised capability (register `0xf0021`, which msm never read); clock recovery collapses exactly when pre-emphasis 3 is driven in. Patch `patches/0018` scopes TPS4 to the sink segment, reads/stores LTTPR PHY caps, and clamps requested levels to the advertised maximum. Stage it over the current dpnext layer with `sudo bash ~/a16.sh msmlttpr`, reboot with the monitor unplugged, confirm the loaded module's **sha256** (the srcversion is identical for the broken and the rebuilt module, so it can no longer tell them apart), start `sudo bash ~/a16.sh display watch dp`, then connect **once**. Revert with `sudo bash ~/a16.sh msmlttpr revert` (before `dpnext revert`) if it does not help. Do not repeat plug/unplug cycles: the last series ended in a freeze and a changed boot ID. Evidence: `evidence/2026-10-02-msm-lttpr-segment-candidate.txt`, `evidence/2026-10-02-repeated-hotplug-dp2-freeze.txt`.
> 2. **Battery charge-control check** — run an unplug/replug measurement. High likelihood of closing this as verified, very low risk.
> 3. **Bluetooth native sequencing** — remove the DTB kill-line workaround by adding this device to `pwrseq-pcie-m2`. Plausible, but needs a matching kernel build and stock-DTB test.
> 4. **Bluetooth rampatch identification** — determine whether a correct `hmtbtfw11.tlv` exists/matches. Research is safe; installing an unverified blob is not.
> 5. **Suspend/resume reliability** — not solved. Keep-MHI-up worked on one resume but a later resume lost the PCIe link and recovery failed. The `pcie_port_pm=off pcie_aspm=off` test is staged, not proven; xHCI/dock and display-after-resume issues also remain. High value, uncertain and higher risk.
> 6. **Internal-speaker audio** — blocked/uncertain; needs machine-specific topology work and may require upstream support.
> 7. **ACPI-mode internal input** — optional; DT boot already supplies working input, so low priority.
>
> Housekeeping (docs, GRUB duplicate cleanup, branch/main integration) is not hardware bring-up and should be handled separately. Do not call a staged patch or a single successful cycle a fix; require repeatable evidence.

## 1. Make Bluetooth permanent: teach `pwrseq-pcie-m2` about this part — `open`, plausible

**Why.** Bluetooth works today because one cell in the patched DTB flips the module's kill line
to active-high. That line is owned by `pwrseq-pcie-m2`, which requests it `GPIOD_OUT_HIGH` and,
because the DTB says `GPIO_ACTIVE_LOW`, drives it physically LOW (kill line asserted) from probe
onwards. The driver only deasserts it inside its `uart-enable` power-sequencing unit, and that
unit has no consumer on this machine: the driver creates the serdev BT device itself only for
PCI IDs in `pwrseq_m2_pci_ids` (`17cb:1103`, `17cb:1107`), and this machine's WLAN/BT part is
`17cb:1112`.

**What.** Add this machine's IDs (device + subsystem, read with `lspci -nn -v` and matched
against the Windows inventory's `QCA_SHB\UART_H4_CLG` device) to `pwrseq_m2_pci_ids`, with the
right `driver_data` compatible string so the driver creates the BT serdev device and sequences
the line itself. Then remove the DTB flags flip (and, if it proves unnecessary, the whole
armed-DTB workaround) and re-verify.

**Verify.** Boot with the stock DTB: the serdev BT device exists (created by the driver), the
line is deasserted without any DTB hack, `hci0` has an address, and the kernel log shows the QCA
version read succeeding.

**Risk.** Low for the DTB side (revertible with `a16-bt-arm.sh revert`). The driver change needs
to be built against the running kernel tree — the bundle is linux-next pin
`3d08ff75a47a3e7e2ab45a3bcab6723b4d906422` (`7.2.0-rc7-next-20260810`), so the module must be
rebuilt from that tree (or the change carried as a patch in the tree's build). No module source
tree is on the A16 yet — item 1a is to bring the tree over or build on the WSL/VM side.

**Upstream value.** This is a genuine upstream patch: "pwrseq-pcie-m2: add FastConnect C7700
(NCM820A) Bluetooth/UART support". It also removes a hack from the A16's boot path.

## 2. Adopt the patched DTB deliberately (and retire the "arming" mechanism) — `small`

**Why.** Right now entries [1]–[4] read DTB files that `a16-bt-arm.sh` has overwritten with the
patched build (`.a16stock` backups are kept). It works, but a kernel/GRUB update, a
`grub-mkconfig`, or a careless `apt` run can replace those files and silently take Bluetooth
away.

**What.** Decide and document the permanent shape, e.g. one of:
- keep the patched DTB as the *canonical* `/boot/glymur-asus-zenbook-a16-ux3607oa.dtb` and treat
  the `.a16stock` file as the fallback, with a `run-once` re-apply script after kernel updates;
- or add a dedicated GRUB entry that loads `/boot/glymur-a16-bt-test.dtb` (entry [8] already
  does) and make *that* the entry the machine boots, reverting the stock paths.

**Verify.** After a simulated kernel update (`apt install --reinstall` of a kernel package, or
`update-grub`), the patched DTB is still the one in use: `dtc -I fs /proc/device-tree | grep
qcom,wcn7850-bt`.

## 3. Audio: a machine ACPI topology for the WSA884x speakers — `blocked` (upstream work), biggest win

**Why.** Card and all four WSA884x amps come up, no deferred probes, a stream reaches RUNNING and
the **DSP consumes nothing**. Cross-SoC topologies are rejected identically
(`Failed to start APM port 105` / `ASoC error (-22)`), the second amp bus (`6ca0000.soundwire`)
reports `SWR bus clsh detected`, and Windows ships no Linux topology — only `acdb_cal.acdb`.

**What.** Build a machine topology around that ACDB (or an upstream one adapted to this
machine's ACDB), then point the card at it. The measurement harness already exists:
`tools/a16-install-tplg.sh`, `tools/a16-audio-graph-test.sh`, `tools/a16-sound-test.sh`.

**Verify.** `tools/a16-audio-graph-test.sh all` shows the DSP consuming the stream and audio
audible on the internal speakers. Until then the documented workaround is to mute the sink
(video then plays).

**Note.** Bluetooth audio already works, so "sound" as a *user-facing* thing is not zero — it is
the internal speakers that are silent.

## 4. Battery: the gauge is fine — verify charge-control across AC/battery — `small`

**Corrected 2026-09-16 (the first reading was wrong).** `cat /sys/class/power_supply/qcom-battmgr-bat/capacity`
is empty because this driver **does not export that property for this variant**: the bound node is
`qcom,glymur-pmic-glink`, which selects `qcom_battmgr`'s **X1E80100** property set, and that list
(on purpose) has no `POWER_SUPPLY_PROP_CAPACITY` — the SC8280XP and SM8350 sets do. What the
driver *does* export is everything needed: `energy_now/full/empty/full_design`, `power_now`,
`voltage_now`, `temp`, `cycle_count`, `manufacture_*`, and the charge-control thresholds. upower
computes the percentage from `energy_*` and reports it:

```
$ upower -i /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat
    state: discharging          energy: 54.51 Wh        energy-full: 66.614 Wh
    energy-rate: 15.582 W       time to empty: 3.5 h    percentage: 81.8296%
    charge-cycles: 42           capacity: 95.1411%      temperature: 30.2 degrees C
```

Also visible and correct: ASUS conservation mode as `charge_control_start_threshold = 75`,
`charge_control_end_threshold = 80` — so "Not charging" while plugged in near 80 % is the *limit
working*, not a fault. (The thresholds are writable: `echo 60 > …/charge_control_end_threshold`
is the conservation control.)

**What is actually left.** Confirm the two directions behave, with
`BRINGUP/tools/a16-power-watch.sh` running across an unplug and a replug:

- on battery: `status=Discharging`, `power_now` negative (~−14 to −18 W here), voltage falling
  slowly, `ac/online=0`;
- on AC: `status=Charging` with `power_now` positive until the end threshold, then `Not charging`
  / `Full` with the charge held (that is the 75/80 window doing its job);
- the percentage follows `energy_now / energy_full` in both directions and `time to empty`
  is plausible.

**Optional.** If a tool or policy insists on reading `capacity` directly (some do), give it the
derived value rather than patching the kernel — a one-line helper, or leave it: upower/GNOME
already show the percentage correctly.

## 5. Suspend/resume reliability — `open`, unresolved and higher risk

**Current status 2026-09-30.** Do not treat `patches/0018` or the keep-MHI-up setting as a complete fix. A successful resume was recorded, but a later one lost the PCIe link and Root Port recovery failed; ath12k then timed out. `pcie_port_pm=off pcie_aspm=off` is a staged test without a repeated success result. Separately, dock USB/ethernet can be lost and the panel can remain dark after resume. See the 2026-09-30 maintainer handoff and the linked 2026-09-22 evidence. Test one change at a time, collect persistent logs, and do not use the risky runtime xHCI module swap.

**2026-09-22, later: the runtime swap crashed the machine.** `wifisleep xhci` loaded the patched
module cleanly (srcversion verified, parameters present) and the *next* resume left a black screen and
no keyboard backlight, so the machine had to be restarted — and a hard reset loses the log, so
patches/0010 still has no recorded suspend attempt.  The swap is now refused by default; land the fix
in the initramfs instead (`sudo bash ~/a16.sh wifisleep xhci persist`, which backs the old one up and
verifies the file list).  Evidence: `evidence/2026-09-22-ladder-runs.txt` §3.

**2026-09-22: the staged fix has never actually run.** `patches/0010` is installed and `modules.dep`
prefers `updates/a16/xhci-plat-hcd.ko`, but the module that is loaded is the **stock** one (srcversion
`B815AC5012DC9B68AE787AF`, no `a16_*` parameters): it is loaded during the initramfs stage from
`/boot/initrd.img-7.3.0-rc3-next-20260914`, which was built 2026-09-16 13:15, before the fix existed.
So the state was not "staged, unverified" but "inert".  End of `~/a16.sh wifisleep` has the two ways to
land it: `xhci` (swap the module for this boot — USB devices re-enumerate, nothing else is at risk)
and `xhci persist` (rebuild the initramfs, with a `.a16bak` copy and a file-list verification first).
Then `lid_sleep test 2` is the proof, and the `A16 …` lines in its log name the root cause.

**Resolved 2026-09-17 (the previous "not attempted" wording was wrong).** Suspend *is* attempted: the
lid is a working `SW_LID` switch on `gpio-keys`, logind suspends on it, and the first suspend of a boot
completes (19 and 88 minutes in the two boots examined). After the resume, **every** later attempt aborts
within a second and logind retries it every ~33 s while the lid is shut:

    kernel: xhci-hcd xhci-hcd.1.auto: PM: dpm_run_callback(): platform_pm_suspend returns -22
    kernel: xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
    kernel: PM: Some devices failed to suspend, or early wake event detected

`-22` is `-EINVAL` from `xhci_suspend()` (`drivers/usb/host/xhci.c`), returned when
`hcd->state != HC_STATE_SUSPENDED` at platform-suspend time; `s2idle` fails the same way, so it is not a
fallback. A closed lid therefore leaves the machine awake: fans on, ~6-7 W, ~10 %/h. Full log evidence:
`evidence/2026-09-17-lid-suspend-wifi-wedge.txt`, page: `docs/suspend.md`.

**Fix staged 2026-09-17: `patches/0010`, installed with `sudo bash ~/a16.sh suspendfix`.** The only
loadable module on the failing path is `xhci-plat-hcd.ko`, so the workaround lives there: when
`xhci_suspend()` returns `-EINVAL` because the USB core left the HCD unsuspended, leave the controller
running and skip the matching resume instead of failing the whole system suspend, and log
`hcd->state`, `hcd->flags`, both root hubs' states, `device_may_wakeup()` and `xhci->quirks` at every
transition. Built natively from `~/build/linux-next-1a1de54f7369`, ABI-checked before install
(vermagic the kernel's, 62 imports identical, `module_layout` CRC `0xe6658f7b`). It does not suspend the
controller (its root cause is still there) and it does not help the Wi-Fi wedge. The three candidate
root causes and what each would need: `notes/2026-09-17-xhci-second-suspend.md`.

**What is left, in order.**

0. Install it, reboot, then `sudo lid_sleep test 2`: both attempts should sleep, and the A16 lines in
   the log name the case (`root_hub=7` = CONFIGURED, i.e. the HCD was never bus-suspended;
   `root_hub=8` = left SUSPENDED). That reading decides the real fix — a USB-core/driver state bug
   means a rebuilt kernel, not this module.
2. Find what the controller refuses: the state of `xhci-hcd.1.auto` (`usb@a400000`) before and after a
   resume, the one device on it (a USB mass storage device, `0bda:0329`, `usb-storage`) — unbind it or
   take it off the bus and try again — and whether it is the USB core's async suspend ordering rather
   than the device.
3. Then the rest of the resume path: the panel (`msm`, `patches/0008` is the insurance against the eDP
   enable/disable reset), Bluetooth (`hci_qca` asked for `hmtbtfw11.tlv` and came up on ROM firmware —
   item 6), and the `msm` GPU path.
4. `sudo lid_sleep lid ignore` is the holding measure: it stops the 33-second retry loop while
   the lid is shut. It does not create sleep.

**Verified 2026-09-17 (same evening): `sleep test 2` is not needed to see it — the lid reproduces it**,
and the *cost* of the one working suspend is now known: its resume kills the Wi-Fi firmware, and the
radio cannot be recovered from software (NetworkManager/wpa_supplicant do nothing, unbind/bind leaves the
netdev gone, the module unload froze the machine — see item 8).  Until this item is solved, the choice is
`sudo lid_sleep lid ignore` (radio alive, machine never sleeps) or one sleep per boot followed by a
reboot.  `reload_wifi`'s driver rungs are behind `A16_I_KNOW=1` for that reason.

**Verify.** `lid_sleep test 2` shows both attempts sleeping, and after each resume Wi-Fi is still
associated and `hci0` still powered.

## 6. Make the Bluetooth rampatch land (`qca/hmtbtfw11.tlv` was not found) — `small`

**Why.** The chip answered, the driver asked for `qca/hmtbtfw11.tlv`, got `-2`, and Bluetooth
came up on ROM firmware anyway. The Windows package ships `hmtbtfw20.tlv`
("`BTFW.HAMILTON.2.0.5-00020`") plus a Cologne set (`clnbtfw10.tlv`, `clnbtnv10.b03/b17`) — none
of which matches the requested name.

**What.** Establish the name/contents pair for a chip reporting `Product ID 0x20`,
`ROM 0x00000101`, `Patch 0x7b40`. Options, cheapest first: check upstream linux-firmware for the
file the driver names; check whether Windows' own NVM/patch for this subsystem is the `cln` set
(and whether Windows drives a different ROM); read `btqca`'s naming code against the version
struct to see exactly which field produced `11`.

**Verify.** Kernel log shows the download completing and a patch version bump; Bluetooth still
works after a reboot.

**Risk.** Low (firmware files are revertible), but a wrong blob can leave BT dead until reboot —
test with `a16-bt-setup.sh install` + a rebind, not a permanent install.

## 7. Display — internal panel and both external outputs work

**Current status 2026-10-02 evening.** Both external outputs work: USB-C DP with the link rate capped at the sink's own 5.4 Gbps (`patches/0019`; persistent through `/etc/modprobe.d/a16-msm-dp-rate.conf`, which the `dprate` staging layer installs) and HDMI at 5120x1440. See item 1 at the top of this file and `docs/display-outputs.md`. The paragraphs below are the history of how this failed before:
*History (2026-10-02).* The internal panel works; external output was disabled. Earlier USB-C tests showed DPTX0 clock enable failure. The staged QMP candidate then reached DP link training #2 on PHY 1, but LTTPR training timed out (`ret=-110`, `rc=-104`); another hard reboot followed. The journal does not identify the reset cause or prove the DP failure caused it. The prior QMP-only trial was reverted and stock modules loaded on the following boot. The new MSM and QMP candidates are now installed as overrides, but the old modules remain loaded until the next reboot. The narrowly patched MSM module restricts the HBR3 override to eDP and guards PUSH_IDLE on failed enable; its 805/805 imported CRCs match. Keep the monitor unplugged; reboot, verify both loaded versions, then start `display watch dp` for one controlled USB-C plug. See `docs/display-outputs.md`, `evidence/2026-10-02-dp-next-candidate.txt`, and `evidence/2026-10-02-qmp-combo-v5-test-hard-reboot.txt`.

**User-visible symptoms (2026-09-16, reported):** no brightness control and no refresh-rate
options in the desktop — no 120 Hz choice, in fact no display settings at all.

**STATUS 2026-09-17 — the display half is solved; a GPU half remains.** The eDP link now trains:
msm binds, `card1-eDP-1` is `connected/enabled` with 2880x1800 at 120 Hz available, and
`/sys/class/backlight/dp_aux_backlight` exists. The fix was the *rate* msm chose, not the PHY —
`patches/0009` takes the highest rate the DT allows (HBR3, 8.1 G) instead of the highest rate the
panel's advertised list stops at (HBR2, 5.4 G), which is the one rate family the v8 PHY sequence
gets wrong. Full story and evidence: `notes/2026-09-17-display-solved-hbr3.md`.

What is *not* solved is the desktop on top of it — and the reason turned out to be our own build,
not the GPU. Starting GNOME oopsed the kernel three times in three different functions, always at
the first `get_pid()` in the module, because every module built from the native tree used wrong
`struct task_struct` offsets: the tree's config was missing `CONFIG_SCHED_CLASS_EXT` (no pahole ->
`CONFIG_DEBUG_INFO_BTF` dropped -> sched_ext dropped -> `thread_pid` at 1824 instead of 2144).

Fixed by `tools/a16-fix-build-config.sh` (pahole + the kernel's config + a top-level
`make syncconfig`, with an ABI check against the kernel's BTF) and a rebuilt `msm.ko`. The desktop
reconfiguration (X11/software GL) that this briefly warranted is *not* needed and was not applied.
Details: `notes/2026-09-17-build-config-mismatch.md`.

**Why, in one line each.**

- *No brightness:* there is **no DRM/KMS driver bound** — the panel is lit by the firmware's
  framebuffer (`simple-framebuffer`, `simpledrmdrmfb`, 2880x1800) and `/sys/class/backlight` is
  empty. A brightness slider needs a backlight class device, which the panel driver registers
  once the real display pipeline is up. (`acpi=off` also removes the ACPI/EC brightness path.)
- *No refresh options:* `simpledrm` exposes exactly **one fixed mode** (`2880x1800`) with no
  modesetting, so there is nothing to choose between — no refresh rates, no resolution/scaling.
- *Both are one item:* get `msm` + the panel driver up and both appear, plus DP output.

**Everything needed is already on the machine.** The machine DTB describes the whole pipeline and
the kernel has the drivers as modules:

| Piece | Where |
|---|---|
| `display-subsystem@ae00000` = `qcom,glymur-mdss` (MDP/DPU + DP + DSI) | machine DTB; `CONFIG_DRM_MSM=m`, KMS/MDSS/DPU/DP/DSI all `y` |
| `msm.ko` | `/lib/modules/7.3.0-rc3-next-20260914/kernel/drivers/gpu/drm/msm/msm.ko` |
| eDP panel `samsung,atna33xc20` under `aux-bus`, `enable-gpios = <&tlmm 18>` (backlight-enable pin state `gpio18`), `power-supply = regulator-edp` (VREG_EDP_3P3), panel power pin state `gpio70`, link rates up to 8.1 Gbps (HBR3 — the kind of link a 2880x1800 high-refresh panel needs) | machine DTB |
| `panel-samsung-atna33xc20.ko`, `phy-qcom-edp.ko`, `dispcc-glymur.ko`, `videocc-glymur.ko` | `/lib/modules/7.3.0-rc3-next-20260914/…` |

They are **blacklisted on purpose** in every working entry
(`module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20`)
because an earlier attempt produced a black screen. Entries **[3]** (msm + panel enabled) and
**[4]** (msm enabled, panel PHY left unmanaged) exist for exactly this work, and the recorded
failure was a clock/power-domain handover problem — `gcc_usb3_tert_phy_com_aux_clk` stuck at
`off`, `Failed to enable clk 'com_aux': -16` (the USB-C DP alt-mode PHY clock, i.e. the *external*
DP path), plus `VREG_EDP_3P3` being disabled by the regulator late cleanup in boots without
`regulator_ignore_unused`.

**Plan, cheapest first.**

1. One boot into entry **[3]** with the boot report enabled, accepting that the panel may go dark:
   the report (`/boot/efi/a16-reports/<newest>/`, plus `tools/a16-display-probe.sh` for a live
   capture) is written by a oneshot unit, so the evidence survives a black screen — reboot into
   [1] afterwards and read it.
2. From that report: which driver claimed `ae00000` first, whether `msm` bound the MDSS, whether
   the panel probed, which clock/power-domain/regulator failed and in what order. The current
   blacklists also blacklist `gpucc_glymur` (absent as a module — harmless) and hide the display
   clocks from `clk_summary`, so the enable order has to be read from the report rather than
   guessed.
3. Fix in the DTB or in the module load order rather than by patching drivers where possible:
   the vendor DTB's `power-domains`/`required-opps`/interconnect values are the first suspects,
   and the panel rail must be claimed by the panel (not ignored) before its probe.
4. Success looks like: `card0` bound by `msm`, `/sys/class/backlight` present and functional
   (slider + Fn keys), the panel's modes listed (2880x1800 and its refresh rates), and an
   external output on the dock.

**Note on the Fn brightness keys:** no internal input device declares
`KEY_BRIGHTNESSDOWN`/`KEY_BRIGHTNESSUP` (`/proc/bus/input/devices`), so they are not a HID path —
they come from the EC, which under `acpi=off` has no driver. Once a backlight device exists, the
compositor can still be driven by the slider; the keys are a separate thread.

### Results of the first two attempts (2026-09-16 evening): both dark, and [4] could not have worked

Ran [4] then [3] as planned; both gave a black screen (the machine was then booted back to [2]).

**Entry [4]** — its kernel log survived (boot id `85f98066`). Facts from it, in order:

```
simple-framebuffer simple-framebuffer.0: [drm] Initialized simpledrm 1.0.0 ... fb0: simpledrmdrmfb
msm-dp-display af54000.displayport-controller: data-lanes not defined, set to default   (x3: af54000,
                                                                                af5c000, af64000)
dispcc-glymur af00000.clock-controller: sync_state() pending due to faac00.phy
dispcc-glymur af00000.clock-controller: sync_state() pending due to af6c000.displayport-controller
platform af6c000.displayport-controller: deferred probe pending: (reason unknown)
adreno 3d00000.gpu: deferred probe timeout, ignoring dependency
arm-smmu 3da0000.iommu: probe failed with error -110
gxclkctl-kaanapali 3d64000.clock-controller: probe failed with error -110
regulator: Not disabling unused regulators
```

and *no* `msm` DRM bind line at all — while systemd reached `graphical-session.target` and
GNOME came up (so the boot itself was healthy; only the picture died).

**Why [4] was constructed to fail.** It blacklists `phy_qcom_edp`, so `faac00.phy` has no
driver; the internal DP controller (`af6c000.displayport-controller`) and `dispcc-glymur` then
wait on it forever, which means `msm` can never bind and the panel can never be driven by Linux.
Its remaining purpose — "does the picture survive while msm's *other* pieces probe?" — was
answered: **no, it does not**, so the killer is in the DP/clock-controller set, not in the panel
driver. (The `adreno`/`arm-smmu`/`gxclkctl` `-110` failures are the GPU/IOMMU path and matter
later for `msm`, but they are not what took the panel down.)

**Entry [3]** — also dark, and it left **no usable log**: the power-cycle came too quickly for
journald to flush the kernel ring (only ~7 s of user-session lines survived). That is a tooling
gap, not a fact about [3].

### What changed so the next attempt is analyzable

- `tools/a16-boot-snapshot.sh` + `tools/a16-enable-boot-snapshot.sh` — a oneshot that runs **45 s
  into every boot** (late enough for the probes) and writes to the **internal disk**
  (`~/a16-payload/boots/<bootid>/`: DRM/backlight, deferred probes, dmesg, `clk_summary`,
  regulator summary, the panel pins' pinctrl state, the kernel journal, power). One `sudo`
  command installs it: `sudo bash BRINGUP/tools/a16-enable-boot-snapshot.sh`.
- `tools/a16-boot-report.sh` now prefers the internal disk and *verifies* its write: the [4]
  boot's report exists in the journal as a path but not on disk — the ESP's FAT dropped it (the
  ESP root still carries `FSCK000*.REC` from a past repair). Never trust the ESP as the only sink.

### ROOT CAUSE, confirmed on the live dark boot (2026-09-16, boot id `f938a244`, entry [3])

The screen is black because **msm never binds**, and msm never binds because the GPU never binds —
and the GPU has no clock/power-domain driver *in this kernel build*:

    $ grep CONFIG_CLK_GLYMUR_GPUCC /boot/config-7.3.0-rc3-next-20260914
    # CONFIG_CLK_GLYMUR_GPUCC is not set
    $ grep -c glymur-gpucc /lib/modules/7.3.0-rc3-next-20260914/kernel/drivers/clk/qcom/*.ko
    0

Every other Glymur clock controller is built (`CLK_GLYMUR_GCC/DISPCC/VIDEOCC/CAMCC/EVACC/TCSRCC=m`);
only the GPU's is missing. The machine DTB asks for `clock-controller@3d90000 { compatible =
"qcom,glymur-gpucc" }`, so that node has no driver at all, and the chain fails exactly as the log
shows:

    adreno 3d00000.gpu: deferred probe timeout, ignoring dependency
    adreno 3d00000.gpu: supply vdd not found, using dummy regulator
    arm-smmu 3da0000.iommu: probe with driver arm-smmu failed with error -110   (clock comes from gpucc)
    gxclkctl-kaanapali 3d64000.clock-controller: probe failed with error -110   (power domain = gpucc)
    qnoc-glymur ...: sync_state() pending due to 3d00000.gpu
    msm_dpu ae01000.display-controller: failed to load adreno gpu
    msm_dpu ae01000.display-controller: failed to bind 3d00000.gpu (ops a3xx_ops): -19
    msm_dpu ae01000.display-controller: adev bind failed: -19

msm's DP/DPU sub-drivers *do* bind (`ae01000` → `msm_dpu`, `af6c000` → `msm-dp-display`, DP
controllers bound), but the DRM master needs the GPU as a component, so no `/dev/dri/card0` from
msm exists, nothing ever drives the panel, and the picture only ever comes from the firmware
framebuffer — hence: no brightness device, no modesetting, no refresh-rate choices, no DP out. The
GPUs' absence is also why the three external DP controllers reported `data-lanes not defined`.

This also means the earlier note "the drivers are all present/installed, only the blacklist
disables them" was wrong for the GPU path: `dispcc`/`videocc`/`phy-qcom-edp`/panel are installed,
the GPU clock controller is **not built**. Corrected here.

The firmware side is *not* a blocker: the GPU blobs are on the machine and the kernel can read them
(`CONFIG_FW_LOADER_COMPRESS_ZSTD=y`, `/usr/lib/firmware/qcom/a740_sqe.fw.zst`,
`gmu_gen70200.bin.zst`, `sm8550/a740_zap.mbn.zst`), and the DTB's adreno node declares no
`zap-shader` property, so the zap path is not required.

### IT WORKED — the display driver came up on 2026-09-16 (boot id `268ff664`, entry [3])

With `gpucc-glymur.ko` installed in `updates/`, the whole chain that used to fail now binds:

| device | before | now |
|---|---|---|
| `3d90000.clock-controller` | no driver (symbol not built) | `gpucc-glymur` |
| `3d64000.clock-controller` | `-110` | `gxclkctl-kaanapali` |
| `3da0000.iommu` (GPU SMMU) | `-110` | `arm-smmu` |
| `3d00000.gpu` | `deferred` → bind `-19` | `adreno` (loads `qcom/gen80100_sqe.fw`, `qcom/gen80100_gmu.bin`; "Zap shader not enabled - using SECVID_TRUST_CNTL instead", so no zap blob is needed) |
| `ae01000.display-controller` | never bound | `msm_dpu` → `card1`, `/proc/fb = msmdrmfb` |

And the panel is a real DRM connector now: **`card1-eDP-1` = connected, `enabled=enabled`, two
2880x1800 modes** (the 120 Hz choice lives here), and **`/sys/class/backlight/dp_aux_backlight`**
exists with `max_brightness=2047` — brightness and refresh-rate control are unblocked by this.

What still fails is the eDP **link**, at the first atomic enable:

    msm_dp_ctrl_link_train_1_2: *ERROR* link training #2 on phy 0 failed. ret=-110
    msm_dp_ctrl_setup_main_link: *ERROR* link training on sink failed. ret=-110
    msm_dp_aux_isr: *ERROR* Unexpected DP AUX IRQ 0x01000000 when not busy
    msm_dp_display_atomic_enable: *ERROR* Failed link training (rc=-104)
    msm_dp_display_atomic_enable: *ERROR* DP display prepare failed, rc=-104

`-110` is a timeout on the AUX/training exchange and the messages name no cause. The lane wiring is
*not* the suspect: `af6c000`'s port@1 endpoint does declare `data-lanes = <0 1 2 3>` and four
`link-frequencies`; the "data-lanes not defined, set to default" warnings are the three **external**
USB-C DP controllers (`af54000`, `af5c000`, `af64000`), a separate item. Likewise the boot's
`WARNING: gcc_usb3_tert_phy_com_aux_clk status stuck at 'off'` comes from `qmp_combo_com_init`
(`phy_qcom_qmp_combo`) — the USB-C DP-alt-mode PHY, not the panel's `qcom-edp-phy` (`faac00.phy`,
which is bound and in use).

### The failing AUX IRQ decodes to the PHY PLL: `DP_INTR_PLL_UNLOCKED`

`0x01000000` in "Unexpected DP AUX IRQ 0x01000000 when not busy" is **BIT(24) =
`DP_INTR_PLL_UNLOCKED`** (`drivers/gpu/drm/msm/dp/dp_reg.h`): the eDP PHY's PLL is unlocking and
the event is handed to `msm_dp_aux_isr`, which is not expecting it while idle. `-110` inside link
training is an AUX *timeout* (`dp_aux_cmd_fifo_tx` waits 250 ms for the AUX completion), which sits
oddly beside the fact that plain AUX reads work — the connector probe read the panel's EDID fine
("ELD monitor ATNA60HR07-0", 30-120 Hz, DisplayID, 10 bpc OLED). AUX is clocked separately, so it
can work while the link/PLL does not.

Everything mechanical on the panel path is verifiably fine on the live boot (from the `edp-debug`
capture): `gpio18 = out high` (the panel's `enable-gpios` is asserted); `VREG_EDP_3P3` = 3300 mV,
enabled, consumer `aux-af6c000.displayport-controller-power`; the PHY's own rails
`faac00.phy-vdda-phy` (21 mA) and `faac00.phy-vdda-pll` (36 mA) enabled; clocks all running —
`disp_cc_mdss_dptx3_link_clk` 540 MHz (HBR2), `dptx3_pixel0_clk` 532 MHz, `dptx3_aux_clk` 19.2 MHz,
`faac00.phy::vco_div_clk` 1.35 GHz, `tcsr_edp_clkref_en` on. And the PHY driver is not falling back
to a generic config: `phy-qcom-edp.c` has `.compatible = "qcom,glymur-dp-phy"` →
`glymur_phy_cfg` → `qcom_edp_phy_ops_v8` with a real Glymur PLL table (1620/2700/5400/8100).
So the fault is at PLL-lock level, not in the rails, the lanes, or the wiring.

### What the debug boot proved (boot id `01af028b`, entry [3] + drm.debug=0x1ff)

Nineteen thousand DRM debug lines, and the failure is now precise. Training runs with
`max_lanes=4, link_rate=540000 (HBR2), pixel_rate=709633` (the panel advertises 162/270/540 Mbps
rates and `max_link_rate=810000`), `LINK_BW_SET: 0x14`, and then:

    link training #1 on phy 0 successful                  <- clock recovery (pattern 1) is fine
    *ERROR* link training #2 on phy 0 failed. ret=-110    <- channel equalization never completes

`-110` is **not** an AUX timeout: `msm_dp_ctrl_link_train_2()` retries until
`drm_dp_channel_eq_ok()` accepts the sink's status and otherwise returns `-ETIMEDOUT`
(`dp_ctrl.c:1626`). `drm_dp_channel_eq_ok()` needs CR_DONE + CHANNEL_EQ_DONE + SYMBOL_LOCKED per
lane (plus interlane alignment), and the sink's own registers say why it never gets there — reads of
DPCD `0x202`:

    11 11 80 04 22 22   lanes: CR done (0x11 each), no EQ, no symbol lock;
                        adjust request 0x22 = swing 2 / pre-emphasis 0
    11 11 00 04 44 44   ... still no EQ/symbol lock, now 0x44 = swing 0 / pre-emphasis 1,
                        interlane alignment (0x204 bit 0) never set

So the sink answers, asks for a drive change, keeps asking, and equalization never converges. The
table behind that drive is the interesting part: on this PHY (`qcom,glymur-dp-phy`, PHY ops **v8**)
the **eDP** path uses the *generic, older* table
(`glymur_phy_cfg.edp_swing_pre_emph_cfg = &edp_phy_swing_pre_emph_cfg`) while the **DP** path on the
same PHY uses a v8-specific one (`dp_phy_swing_pre_emph_cfg_v8`) with materially different values
(at swing 0 / pre-emphasis 1: eDP `swing 0x11, pre 0x15` vs v8-DP `swing 0x12, pre 0x0c`).

### Negative result, and two things the same log ruled out

`patches/0004` (eDP path → the v8 drive table) changed nothing: link training #2 failed exactly
the same way, with the same status bytes. So the *drive table values* are not the lever.

The same log also settled two other suspects, and both are **correct as-is**:

* the EQ pattern is TPS3, and that is right — `drm_dp_tps3_supported()` reads
  `dpcd[DP_MAX_LANE_COUNT] & (1<<6)`, and this panel's `0x00002 = 0xc4` has that bit set (bit 7 too),
  with `DP_DPCD_REV = 0x14`. The driver wrote `DPCD 0x102 = 0x23` (TPS3, scrambler disabled).
* disabling the scrambler for TPS2/TPS3 is the convention, not a mistake: i915 does exactly that
  (`"Scrambling is disabled for TPS2/3 and enabled for TPS4"`, intel_dp_link_training.c).

### Is there an upstream patch? No -- verified against today's upstream

Checked by fetching the current files from linux-next master (which is *ahead* of our 2026-09-14
pin) and diffing them against the tree we build from:

| file | vs today's upstream |
|---|---|
| `drivers/phy/qualcomm/phy-qcom-edp.c` | identical (only our two experiment patches differ) |
| `drivers/gpu/drm/msm/dp/dp_ctrl.c` | identical |
| `drivers/gpu/drm/msm/dp/dp_link.c` | identical |
| `drivers/gpu/drm/msm/dp/dp_panel.c` | identical |
| `drivers/gpu/drm/panel/panel-samsung-atna33xc20.c` | identical |
| `drivers/phy/qualcomm/phy-qcom-qmp-combo.c` | differs (402 lines) -- the USB-C combo PHY, not the internal panel |

So there is no newer kernel code to try for this path: we are already on the newest upstream support
that exists for this machine.

And the device tree is upstream's own: building
`arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dts` from our tree produces
`sha256 ddb423f8dda683a965c1ffe6c4933d15bd9714dae7e740faf8d306b968056ac2` -- **bit-for-bit the stock
DTB this machine boots**. Upstream carries a DTS for the A16 UX3607OA, and we have been running it
all along. (That also corrects an earlier note in this repo which claimed upstream's DTS could not be
used because it has no `/memory` node -- whatever the truth of that was, the file we boot *is* the
upstream build.)

Which means: this is an upstream bug that nobody has hit (or nobody has tested at 120 Hz), and our
evidence is what a fix would need.

### Retired candidates so far

| change | result |
|---|---|
| eDP path → v8 drive table (`patches/0004`) | identical failure |
| `TXn_TRAN_DRVR_EMP_EN` 0x01 → 0x5f (`patches/0005`) | identical failure (`link training #2 ... ret=-110`) |

Both were one-variable builds installed into `updates/a16/`; removing that file and running
`depmod -a` restores the stock module.

### Next experiment: is it the *mode*? (120 Hz / HBR2 vs 60 Hz)

Every attempt so far ran the panel's preferred 2880x1800 **@120 Hz**, which needs 4 lanes at HBR2
(540 MHz): `rate=540000, num_lanes=4, pixel_rate=709633`. If upstream's own testing was done at
60 Hz, the HBR2 path may simply be the untested/broken one -- and that is testable, with a bonus: if
the lower rate trains, the panel lights.

    sudo A16_PARAMS="drm.debug=0x1ff video=eDP-1:2880x1800@60 systemd.unit=multi-user.target" \
        bash BRINGUP/tools/a16-drm-debug-entry.sh arm
    reboot and pick [3]

`video=eDP-1:2880x1800@60` pins the console to the 60 Hz mode; `systemd.unit=multi-user.target` keeps
GDM/GNOME out of the way so nothing re-modesets back to 120 Hz. If the link trains, the panel shows
the **text console** and the log says `link training #2 on phy 0 successful`; if it stays dark, the
failure is mode-independent and the HBR2 idea is retired as well. Undo afterwards with
`sudo bash BRINGUP/tools/a16-drm-debug-entry.sh remove inline`.

### The candidate that matches the symptom: the emphasis enable mask

The sink's only complaint is pre-emphasis: it reports CR done on all four lanes, never EQ, and keeps
asking `DPCD 0x206/0x207 = 0x44` (swing 0 / pre-emphasis 1) over and over. The shared TX setup in
`phy-qcom-edp.c` writes

    writel(0x01, edp->tx0 + TXn_TRAN_DRVR_EMP_EN);   (and tx1)

while Qualcomm's own driver for this PHY generation writes **0x5f** to the equivalent register
(`phy-qcom-qmp-combo.c`: `QMP_PHY_INIT_CFG(QSERDES_V8_LALB_TRAN_DRVR_EMP_EN, 0x5f)`; the older
generations use 0x03/0x0f there). One tap enabled instead of the full set would leave the panel's
requested pre-emphasis unreachable — exactly the observed non-convergence. Strong circumstantial
evidence, not proof.

Staged as `patches/0005-phy-edp-glymur-emphasis-enable-experiment.patch`: 0x01 → 0x5f on both TX
blocks, built as `phy-qcom-edp.ko` (vermagic exact, `module_layout` CRC `0xe6658f7b`, all imports
versioned). One variable changed — 0004 is reverted, so the table in this build is the stock one:

    sudo bash BRINGUP/tools/a16-install-gpucc-module.sh \
        ~/build/linux-next-1a1de54f7369/drivers/phy/qualcomm/phy-qcom-edp.ko
    reboot and pick [3]

Success looks like `link training #2 on phy 0 successful` and then a picture; failure looks like the
same line with `ret=-110`, which would retire this candidate too and leave the PHY's TX register map
(the "do the writes land at all" question, answerable by reading the PHY's registers with `/dev/mem`)
as the next thing to test.

### Superseded experiment: give the eDP path the v8 drive values

`BRINGUP/patches/0004-phy-edp-glymur-edp-swing-table-experiment.patch` (one line:
`.edp_swing_pre_emph_cfg = &dp_phy_swing_pre_emph_cfg_v8`), built as `phy-qcom-edp.ko` against the
same tree/config — vermagic exact, `module_layout` CRC `0xe6658f7b` = the kernel's, all 40 imports
versioned:

    sudo bash BRINGUP/tools/a16-install-gpucc-module.sh \
        ~/build/linux-next-1a1de54f7369/drivers/phy/qualcomm/phy-qcom-edp.ko
    reboot into entry [3]

Read `~/a16-payload/boots/<newest>/` or the journal afterwards: if `link training #2 ... successful`
appears, the drive calibration was the fault and the patch belongs upstream. If it fails the same
way, the calibration is not the cause and the next suspects are the training pattern choice (TPS2 vs
TPS3/TPS4), the scrambler, and the rate/lane combination — all visible in the same debug log.

### Previous technique: capture a fresh link-training attempt with DRM debug on

`a16-edp-debug.sh` did its job (it produced the state above, and it showed that `dpms` is not
writable on this kernel, so a live re-train has to come from a boot). The remaining question is which
AUX transaction inside link training times out and what the sink answers, which only `drm_dbg_dp` —
i.e. `DRM_UT_DP` — reports:

    sudo bash BRINGUP/tools/a16-drm-debug-entry.sh add inline   # puts drm.debug=0x1ff in entry [3]
    reboot and pick [3]                                         # no new row to find
    # afterwards: sudo bash BRINGUP/tools/a16-drm-debug-entry.sh remove inline

Two traps the script now handles, both learned here: the menu exists in **four** ESP files
(`/a16boot/grub.cfg`, which is ours, plus byte-identical copies under `/EFI/Boot`, `/EFI/ubuntu`
and `/EFI/ubuntu_snapdragon`) and the firmware reads one of the `/EFI` copies — editing only
`/a16boot/grub.cfg` looks like it worked and changes nothing, which is exactly why a "debug" boot
came up with no `drm.debug` and looked identical to the boot before it. `add inline` therefore
edits every config that carries the menu, idempotently, with a `.a16-drmdebug-bak` per file and a
byte-identical `remove inline`.

`drm.debug=0x1ff` turns on every DRM category (driver, KMS, atomic, DP); the log lands in the
persistent journal, so it can be read afterwards even if the picture never comes up.  Then:

    sudo journalctl -k -b -1 | grep -iE 'link train|aux|dpcd|pll|pattern|swing|pre-emph'

That should show the sink's link caps, the rate/lane/voltage-swing choices, each training attempt and
the exact AUX transaction that returns -110. `a16-drm-debug-entry.sh remove` puts the menu back
(verified: byte-identical round trip, `grub-script-check` clean). Side note: the menu still carries
the duplicated `[8]` entry — `sudo bash BRINGUP/tools/a16-grub-dedupe.sh` clears it whenever wanted.

### Next experiment: build the one missing module, install it, boot [3]

0. **Or build it right here, natively** — preferred, and now proven feasible: the installed bundle
   carries `metadata/linux-next-commit.txt` (`1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`) and
   `metadata/kernel.config` is byte-identical to `/boot/config-<ver>`, git.kernel.org serves a source
   snapshot of that exact commit, and the kernel's symbol CRCs (what `CONFIG_MODVERSIONS` needs) can
   be harvested from the installed modules via `modprobe --dump-modversions`. One script, two stages:
   `bash BRINGUP/tools/a16-build-gpucc-native.sh --fetch` (no root: fetch tree, drop in the config,
   enable the symbol, harvest `Module.symvers`) then `--build` (after
   `sudo apt install -y build-essential flex bison libssl-dev libelf-dev libdw-dev libncurses-dev bc`), then
   `sudo bash BRINGUP/tools/a16-install-gpucc-module.sh <the .ko>`. Release build dirs
   (`~/build`, `linux-next/`) are gitignored. The module is unsigned (`CONFIG_MODULE_SIG_FORCE` is
   not set, so it loads; the kernel taints).
1. **On the build side** (WSL/VM), if a native build is not wanted:
   `bash BRINGUP/tools/a16-build-gpucc-module.sh /path/to/linux-next`
   → enables `CONFIG_CLK_GLYMUR_GPUCC=m`, rebuilds *only* `drivers/clk/qcom`, checks the module's
   vermagic against the running kernel, and writes `~/a16-export/gpucc-glymur-7.3.0-rc3-*.tar.gz`.
   A module-only build is legitimate here: same tree, same `.config` + the one symbol, same
   `Module.symvers`, so vermagic and symbol CRCs match. No kernel rebuild, no DTB change. Two
   gotchas that cost a run each: the kernel has `CONFIG_EXTENDED_MODVERSIONS=y`, so the host needs
   `libdw-dev` (`gendwarfksyms` wants `dwarf.h`), and modpost's symbol-dump parser wants **five**
   fields (`0xcrc<TAB>symbol<TAB>module<TAB>export<TAB>namespace`) — a four-field file dies with
   "parse error in symbol dump file".
2. **On the A16**: already built and verified. The genuinely missing module is exactly one —
   `gpucc-glymur.ko` (388 368 B, vermagic `7.3.0-rc3-next-20260914 SMP preempt mod_unload modversions
   aarch64`, `module_layout` CRC `0xe6658f7b` = the kernel's, every import versioned, no modpost
   warnings). Install with
   `sudo bash BRINGUP/tools/a16-install-gpucc-module.sh ~/build/linux-next-1a1de54f7369/drivers/clk/qcom/gpucc-glymur.ko`
   — into `/lib/modules/<ver>/updates/a16-clk-qcom/`, where depmod makes `updates/` win over
   `kernel/`, so nothing shipped is overwritten and removal is `rm` + `depmod`. Name the file
   explicitly: the build directory also holds ~30 freshly compiled sibling CC modules that must
   **not** be installed.
   Correction to the section above: `gxclkctl-kaanapali.ko` is *not* missing — `CONFIG_CLK_KAANAPALI_GPUCC=m`
   already builds it (`drivers/clk/qcom/Makefile` shares it across five GPUCC symbols), and it is
   installed. It failed with `-110` only because its power domain (gpucc) was absent, so its fix is
   the same one module. A rebuilt copy exists but should not be installed.
3. Reboot into **[3]**, wait ~90 s, read the snapshot (`ls -t ~/a16-payload/boots | head -1`).
   Expected, in order: `3d90000.clock-controller` binds → `3da0000.iommu` probes → `adreno 3d00000.gpu`
   binds (GMU firmware loads) → `msm_dpu` binds → `card0` is msm's → `/sys/class/backlight/` appears,
   refresh modes appear. SSH is now in place, so a dark panel no longer costs a power-cycle.
4. If msm binds but the panel still stays dark, the next suspects are unchanged (the `dispcc-glymur`
   handover, the eDP PHY bind order, the panel's `power-supply`/enable GPIO) — but now the snapshot
   and the journal will say which, which is what the two dark boots lacked.

## 8. Wi-Fi: the recovery tool exists; the profile problems remain — `small`

**2026-09-22: the wedge is a firmware that never comes back, and the answer is not in upstream.**
The MHI lines before the resume timeout are `Power on setup success` → `Wait for device to enter SBL
or Mission state` and nothing after: the QCC2072 is no longer running firmware after a deep suspend,
and the resume path never re-downloads it (that lives in the probe path) — which is why a reboot, a
probe, fixes it.  `ath12k/core.c`, `mhi.c`, `wow.c` and `qmi.c` at linux-next master 2026-09-22 are
byte-identical to the tree this kernel came from, and there is no ath12k suspend/resume patch in
flight, so nothing released or posted can be brought in for this path.

**2026-09-22, later: the ladder was run, and it narrowed to the driver.**  s2idle kills the radio too
→ it is ath12k's own resume path, not platform power.  `modprobe -r ath12k_wifi7 ath12k` **hangs the
machine** (healthy radio; the 2026-09-17 freeze was not about the wedge) → the reload hook is out, and
so are the driver-teardown rungs of `reload_wifi`.  The EC driver (item 12) binds and works but did not
rescue the radio.  What is left is the driver: **`patches/0014`** — the resume ran the WiFi SoC's
global reset and threw away the firmware the suspend deliberately kept (`mhi_power_down_keep_dev()`),
with nothing re-downloading it; the patch skips the reset on a resume and logs both MHI states.  Built,
ABI-verified, and now **one command to run over SSH**: `sudo ~/a16step` (install → restart → test →
verdict; `sudo bash ~/a16step.sh` is the same thing spelled out).
`test [n]` is still the measuring instrument and `forensics` is for the next wedge (bus/PowerState,
then a PCI reset + rebind).  Evidence: `evidence/2026-09-22-ladder-runs.txt`; page:
`BRINGUP/notes/2026-09-22-wifi-suspend-ladder.md`.

**Resolved 2026-09-17: "leaving the machine alone loses Wi-Fi" is a resume failure, not an idle one.**
The radio's firmware stops answering on the resume of the one suspend per boot that completes
(`failed to resume core: -110`, then `wmi command 16387 timeout` forever), after which the interface
cannot be brought up and the desktop lists no networks. Reboot is no longer the only cure:

    sudo reload_wifi               # diagnose, then climb the ladder until the radio is back
    reload_wifi status             # read-only, no root      (`reload_wifi --help` lists every mode)

`tools/a16-wifi-recover.sh` restarts NetworkManager, then wpa_supplicant, then unbinds/binds
`ath12k_wifi7_pci`, then reloads the modules, then removes the PCI function and rescans the bus —
cheapest first, stopping at the first rung that associates. Which rung it was is the finding: the first
two mean NetworkManager had given up, the later ones mean the firmware was wedged. Evidence:
`evidence/2026-09-17-lid-suspend-wifi-wedge.txt`, page: `docs/wifi.md`.

**Run on a real wedge 2026-09-17 — the recovery ladder does not recover it.** Restarting NetworkManager
and wpa_supplicant: nothing.  Unbind/bind `ath12k_wifi7_pci`: the netdev goes away and does not come
back.  `modprobe -r ath12k_wifi7 ath12k`: **the whole machine froze and needed a hard reset.**  So
`reload_wifi` now runs only the harmless rungs by default, the four driver-teardown rungs are gated
behind `A16_I_KNOW=1`, and a wedged radio means a reboot.  The lever that works is prevention:
`sudo lid_sleep lid ignore`, because the wedge lands on the resume of the one suspend per boot that
completes (item 5).  Nothing here is worth doing again on a wedged radio; what *is* worth trying, on a
healthy boot, is whether the same rungs behave (they are the normal way to reset a driver) — that would
say whether the freeze is the driver's teardown in general or only after a wedge.

**What is left.** The profile behaviour this item was written for: the profile picks the AP's weakest
6 GHz BSSID (−77 dBm) instead of its 100% 5 GHz/2.4 GHz ones, and the dock's Ethernet holds the default
route. `tools/a16-wifi-tune.sh` (band preference, powersave, route metrics), then measure throughput and
which BSSID is chosen across a reconnect.

## 9. ACPI-mode internal input — `open`, optional

**Why.** Only needed if an ACPI fallback must be usable. The firmware describes the I2C
controllers as `ACPI\QCOM0F10` and the GPIO controller as `ACPI\QCOM0F0C`; nothing in linux-next
matches either, so no I2C adapter appears and the four firmware I2C-HID children never enumerate.
DT mode is the working route — this is driver work on the match tables.

## 10. External displays: why the combo PHY's clock bundle is refused — **resolved** (clock domain 2026-09-17, the remaining freeze 2026-10-02)

**Why.** Plugging a monitor into USB-C or HDMI used to freeze the desktop. The clock half was fixed on 2026-09-17 (the tertiary PHY's power domain had no consumer — see item 7 above); the remaining freeze, a DPU flush left pending after a failed link training, is addressed by `patches/0020` (dropped in that timeout path so a dead sink costs the external picture, not the desktop). The cause was known rather
than guessed: the QMP combo PHY cannot enable its clocks, so the DP controller's enable returns
`-EBUSY` and the atomic commit that would bring the output up never completes. The HDMI side of this
reproduces at **every boot with nothing plugged in** (`gcc_usb3_tert_phy_com_aux_clk status stuck at
'off'`, raised from `qmp_combo_com_init`), so it can be worked on without a monitor and without
risking a freeze — which is what makes it worth doing before the upstream PHY series lands.

**What.** The clock table is cleared (measured: the tert `com_aux` CBCR at `0x1e1074` holds
`0x88000001` — enable bit set, halt bit still set — while the working sec twin holds `0x08000001`,
and the neighbouring `aux` branch asserts with the same parent RCG). So is the software side of the
PHY itself: the `refgen` rail is requested (this generation's cfg uses `qmp_phy_vreg_refgen`), the
resets run, `gcc_usb_2_phy_gdsc` is on and the TCSR reference bit gets enabled before `com_aux` does.
A userspace register poke cannot settle the rest (`/dev/mem` writes are refused under
`CONFIG_STRICT_DEVMEM=y`, and the framework's write knob is compiled out), so the immediate step is the
one thing that is *off*: the instance's controller domain `gcc_usb30_tert_gdsc`, whose register page
(`0xe1010` GDSCR with the `0xe1070/74/78` CBCRs and the `0xe1080` RCG) is where the COM block sits, and
whose only DT consumer `usb@a000000` this machine's DTB leaves disabled. `tools/a16-tert-phy-power.sh`
(`sudo bash ~/a16.sh tertphy arm [bridge]`, `check` after the reboot, `revert`) puts a DT consumer on
that domain and reports whether the domain and the clock come up.

**Result of the first lever (2026-09-17, `tertphy arm`).** Inconclusive, and the reason is precise:
with `usb@a000000` enabled (live DT `status = okay`, both DTB copies armed) the domain stayed `off`
and the clock kept refusing, because that consumer never finished probing —
`platform a000000.usb: deferred probe pending: dwc3-qcom: failed to register DWC3 Core`
(`dwc3_qcom_probe` → `dwc3_core_probe`, drivers/usb/dwc3/dwc3-qcom.c:710), i.e. -EPROBE_DEFER
waiting on the same combo PHY that is failing. A consumer that cannot bind votes for nothing, so
this route is a dead end rather than a negative result. Evidence:
`BRINGUP/evidence/2026-09-17-tertphy-domain-check.txt`.

**Second lever, and its result: `sudo bash ~/a16.sh tertphy arm bridge`.** It gives
`/hdmi-bridge` (`parade,ps185hdm`, driver `simple-bridge`, binds on every boot) a single
`power-domains = <&gcc GCC_USB30_TERT_GDSC>`. The platform bus calls
`dev_pm_domain_attach(dev, true)` before probe, and with exactly one power-domain specifier
`genpd_dev_pm_attach()` calls `genpd_power_on()` (drivers/pmdomain/core.c:3411) — the domain is
forced on at attach, with no dependency on any other driver binding. (A device with two or more
specifiers is skipped by that path entirely, core.c:3457, so this cannot be appended to
`phy@88e1000`, which already carries one.) Boot 3a63a313 (12:05): **`gcc_usb30_tert_gdsc` reads
`on`, and the boot has no `com_aux` / `stuck at 'off'` / `phy init failed` / `dptx1_link_clk` line
at all** (the previous boot had them). So the COM clock was only unpowered: the fix is a DTS
change (the domain needs a consumer, or a keepalive vote), not the upstream PHY programming series.
What is still unproven is an output: `card1-HDMI-A-1` stays `disconnected` with nothing plugged, so
the next test is a monitor — `sudo bash ~/a16.sh display watch` over SSH, plug in, watch for link
training, and `sudo bash ~/a16.sh display recover` if the picture freezes instead (kernel survives;
patch 0008 is the insurance). `tools/a16-phy-clock-test.sh`
(`sudo bash ~/a16.sh phyclock read`) still gives the registers, TCSR words and rails.

**Verify.** `sudo bash ~/a16.sh phyclock read` still prints the tert group's CBCR words next to the
working sec control's, the two TCSR ref words and the rails they depend on (its `cycle` can no longer
write anything — `/dev/mem` writes are refused on this kernel and it says so). The test that can move
this is `sudo bash ~/a16.sh tertphy arm bridge`, then `check` after the reboot into [3]: the domain
`gcc_usb30_tert_gdsc` should read `on` and `gcc_usb3_tert_phy_com_aux_clk` should come up with no
`stuck at 'off'` line in that boot's log — in which case the DTB line is the fix; if the domain comes on
and the clock still refuses, the blocker is the upstream PHY work; `revert` puts the DTB back.

## 11. Housekeeping — `small`, do as you go

- Run `tools/a16-grub-dedupe.sh` once (the duplicate BT menu row written by the old idempotency
  check is still in the four ESP configs).
- Refresh `STATUS.md` and the notes for this window; keep `notes/` current (it is the evidence
  trail the README links to).
- Decide the branch story: this work lives on `bringup-2026-09-16`; the earlier era is on
  `feature/tumbleweed-a16-live-iso` and archived in `archive/2026-09-16-pre-bringup/`. Nothing
  here belongs on `main` until it is cleaned up.
- When item 1 lands, remove the superseded tool (`a16-bt-enable.sh`) or fold its read-out into
  `a16-bt-setup.sh status`.

## 12. Embedded controller: take the posted driver (2026-09-17) — `small`, built and staged

**Why.** This machine's EC (I2C address `0x76` on i2c9, event interrupt on TLMM gpio66) has no driver,
so nothing has ever told the EC about a suspend — and the EC is the part that owns platform power on
these designs. That is a prime suspect for the Wi-Fi module losing power across a deep suspend
(item 8), and it also buys fan RPM, two temperature sensors, keyboard backlight and sideband events.

**What.** "[PATCH 0/3] Asus Zenbook A16/A14 (UX3607OA/UX3407NA) EC driver", Konrad Dybcio, 2026-09-17 —
carried here as `patches/0011..0013` after they applied cleanly to the build tree. State: v1, under
review (Krzysztof Kozlowski on the bindings; Abel Vesa `Reviewed-by` on the DTS), not in linux-next.
The module is built natively and ABI-verified (vermagic the kernel's, `module_layout` `0xe6658f7b`, all
25 imports CRC-checked); the DTB is armed by adding the node to the live DTB so the Bluetooth and
tert-PHY changes stay.

**Installed 2026-09-22 and working.** `9-0076` → `asus-glymur-ec`, hwmon `asus_glymur_ec` (fans
~1980/1320 RPM, two temperature sensors), `asus::kbd_backlight` (0-3; **the default is 0, which is why
the keyboard backlight looked missing** — `sudo bash ~/a16.sh ec kbd 2`), event IRQ on gpio66, and the
EC now receives suspend entry/exit.  It did not rescue the radio (s2idle still wedges it) — see item 8.

**Do it.** (already done) `sudo bash ~/a16.sh ec install` → start again into [3] → `bash BRINGUP/tools/a16-ec.sh verify`.
Revert with `sudo bash ~/a16.sh ec revert` (module out, `.a16ecbak` DTBs restored).

**Verify.** `/sys/bus/i2c/devices/9-0076` exists and binds `asus_glymur_ec`; hwmon shows the two fans
and the temperatures; `asus::kbd_backlight` exists; the kernel log has no EC probe error. Then the
question this is really for: `sudo bash ~/a16.sh wifisleep test` — the radio surviving the first deep
suspend would mean the EC was the missing half of the suspend path (item 8).

**Upstream value.** The driver is posted by its author; if it needs a fix for this machine's firmware
(e.g. an event-enable the probe does not send), that is a patch worth sending back.

## After 2026-09-22 — the Wi-Fi wedge is closed, three things follow from it

1. **The lid should go back to sleeping.** `sudo lid_sleep lid suspend` (it is on `ignore` while the
   resume was broken). Then one full cycle: close the lid, open it, expect the radio to stay up and
   `a16.sh display hook` to bring the panel back. If that holds, the laptop behaves normally.
2. **The one casualty a resume still has: `xhci-hcd.1.auto` dies** (`WARNING: Host System Error`,
   `arm-smmu ... Unhandled context fault ... SID=0xda0`, `HC died; cleaning up`), so the dock's USB and
   ethernet need a reboot. `patches/0010` (patched `xhci-plat-hcd.ko`) was written for exactly this and
   has never been the loaded module; the route is the initramfs one —
   `sudo bash ~/a16.sh wifisleep xhci persist`, then reboot. The runtime module swap is refused because
   it crashed the machine; the persist path rebuilds the initramfs and is untested.
3. **The panel's dark-after-resume has a workaround, not a cause.** The output is left
   `enabled=disabled`; who disables it is unknown. Next look: arm `drm.debug=0x1fe`
   (`sudo bash ~/a16.sh display arm`), resume once, and read what disables the CRTC — the resume itself
   completes cleanly, so it should be visible in the log.
4. **Housekeeping for the driver stack.** With `a16_keep_mhi_up=Y` the reset-skip and re-attach
   machinery (`patches/0014`/`0015`) is bypassed entirely: the fix that is doing the work is 0018, with
   0016/0017 as the safety net for a resume that fails anyway. Worth trimming to that and writing up
   for upstream — the suspend destroying the host side while the firmware survives is a real driver bug,
   not a board quirk.
