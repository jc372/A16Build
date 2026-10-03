# A16Build — STATUS.md

> The pick-up sheet. Any agent reads this plus `AGENTS.md`, then `docs/index.md` for the component
> guides. Update after any work on this machine.

**Maintainer handoff quick link:** [A16 ath12k board-data and suspend/PCIe report](BRINGUP/notes/2026-09-30-ath12k-maintainer-handoff.md) (includes the upstream thread and a draft post).

**As of:** 2026-10-02 · **Last updated by:** Hermes · **Branch:** `main` now carries this work — fast-forwarded from `bringup-2026-09-16` on 2026-10-02, both refs verified against `origin` in this clone. This clone pushes with the staged credential (`GIT_ASKPASS=~/.local/git/github-askpass.sh` with `A16_TOKEN_FILE=~/.a16-git-token`, git from `~/.local/bin`); commits are authored as `agentbhome`, never as the operator.

**Current open-work summary (verified against the 2026-09-30 maintainer handoff, the machine's current boot, and 2026-10-02 hotplug evidence):**

- **GDM login reliability: root cause found and the fix APPLIED 2026-10-03 09:50 EDT; effective from the next full boot.** (The root log is `~/a16-payload/gdm-session-fix-20261003-095015.log` and `loginctl show-user jc -p Linger` now reads `no`.) `Linger=yes` for `jc` causes the user manager to start before the greeter; the current boot confirms a seat-less manager session predates the graphical login. `sudo bash ~/a16.sh gdmfix` disables lingering without restarting GDM; after a normal shutdown/boot, the manager (and Hermes Gateway) starts at local login. Log in locally before opening SSH as `jc`. See `notes/2026-10-03-session-manager-trap.md`.
- Internal panel works in the built-driver boot. **External displays work too, as of 2026-10-02 evening: the Gigabyte trains over USB-C DP at a 5.4 Gbps link rate on either port (hotplug included) and the MSI runs over HDMI at 5120x1440** - see the two dated entries below for the patches, hashes and evidence; the paragraphs that follow in this bullet are the history of how the external path failed before that. Earlier USB-C captures showed DPTX0 clock stuck off and `ctrl_link` `-16`; the staged QMP candidate was then loaded and tested. On 2026-10-02, the attempt reached DP link training but failed LTTPR training (`ret=-110`, `rc=-104`), followed by another hard reboot reported by the operator. The prior boot journal ends immediately after the DP AUX error; reset cause and causality remain unknown. Revert and reboot were verified: at 14:16:55 EDT the stock module was loaded (`srcversion` `63A1B2708C9E05A81BA565D`), modprobe resolved to the stock module, and the override and rollback state were absent. Analysis found a concrete local defect: the eDP-only HBR3 rate override was also forcing every external DP connector to 8.1 Gb/s, bypassing the sink/LTTPR rate cap; `phy 1` in the failure is LTTPR1, not the physical QMP #1. A second, separately posted A16-tested guard prevents PUSH_IDLE after failed enable, a possible but unproven reset trigger here. An updated `msm.ko` with these two narrow changes builds and matches all 805 imported CRCs; the earlier QMP v5 candidate is reusable. Both candidates are now loaded after reboot (boot ID `dde44d2c-f6c8-4de3-8ec0-de35e0e8c131`, verified 15:00 EDT): MSM `BBD010BD47287F02B65EE84`, QMP `151CA3C3BDC39CA185C951B`; eDP remains connected/enabled, DP-1/DP-2/HDMI disconnected. Both module resolvers and rollback directories remain in place. The staging script had verified both module bytes/initrd entries. The 15:03 USB-C attempt did not reboot: DP-1 was detected and `enabled=enabled`, but no external picture; link training at 8.1 Gbps/4 lanes failed LTTPR1 channel equalization and DPU timeouts followed. The internal panel blacks out during the attempt but recovers when USB-C is unplugged, without reboot or GDM restart. Boot ID did not change; the watcher was stopped with Ctrl-C and restored DRM debug to 0. DP-only logs show LTTPR1 clock recovery passes at 8.1 Gbps/4 lanes, then EQ requests pre-emphasis levels 1→2→3 without converging. Do not repeat this unchanged hotplug; the captured trace is sufficient to investigate the QMP PCS LN0/LN1 drive-level update path. Evidence: `BRINGUP/evidence/2026-10-02-dp-next-black-panel-no-reboot.txt`.
- **Two-monitor session (2026-10-02 17:23-17:31) puts the external-DP failure on the link rate, not the monitor or the port.** Four sessions with the LTTPR candidate live: Gigabyte on DP-1 (3440x1440) worked - zero prepare failures, zero timeouts, plug/unplug tolerated; MSI on DP-2 (5120x1440), Gigabyte on DP-2 and (earlier) MSI on DP-1 all failed identically. Every failure is the LTTPR segment's channel equalization never converging with pre-emphasis already at maximum (`link training #2 on phy 1 failed. ret=-110` -> `link training of LTTPR(s) failed` -> `rc=-104` -> `DP display prepare failed`), followed by DPU `vblank timeout` / `wait for commit done -110` storms and a frozen desktop; the internal panel is retrained successfully in the same atomic enable, so the freeze is the failed external encoder leaving the commit path stuck. The same monitor moved from working to failing by changing port, so neither the monitor nor the port alone decides it. Why the rate: the monitors' basic DPCD block says HBR2 (`0x00001 = 0x14` = 5.4G) while their DPRX extended receiver capability block says HBR3 (`0x02200` byte1 = `0x1e` = 8.1G), and `drm_dp_read_dpcd_caps()` merges the extended block over the basic one, so `msm_dp_panel_read_link_caps()` asks for 8.1G x4 on a link only guaranteed at 5.4G - and no rate down-shift is ever attempted (only `LINK_BW_SET 0x1e` appears in any capture; the retry loop's `msm_dp_ctrl_link_rate_down_shift()` is never reached after an LTTPR failure). The eDP-only scope of the local HBR3 workaround was verified correct (`dp_panel.c:200`). This also settles the LTTPR candidate (patch 0018): **insufficient, not harmful** - identical `ret=-110`. Evidence: `BRINGUP/evidence/2026-10-02-gigabyte-vs-msi-port-pattern.txt`.
- **dprate candidate REBUILT 2026-10-02 18:05 with two patches - the rate cap plus a freeze mitigation - and not staged yet.** New: `BRINGUP/patches/0020-dpu-drop-stuck-flush-after-vblank-timeout.patch`. When an external DP link fails training, its DPU interface has no pixel clock, so the vsync that clears `CTL_FLUSH` never arrives and `dpu_encoder_phys_vid_wait_for_commit_done()` times out (50 ms) on *every* later commit on that CRTC - and because one atomic commit covers both CRTCs, the internal panel stops updating too: that is the observed freeze, and only a reboot clears it. The patch drops the stuck pending flush in that timeout path, so the pipeline keeps running, the commit still reports the timeout, and the external output simply stays dark. Candidate: srcversion `F60D32C034D8487FB39FE42`, sha256 `c90b9d8e313d224b73238998ffb53fb8c152c25513ddc8c91bc296a896554328`, ABI gate PASS, `thread_pid` 2144, `module_layout` `0xe6658f7b`, cap parameter present. The `dprate` stage script now also installs `/etc/modprobe.d/a16-msm-dp-rate.conf` (`options msm a16_dp_max_rate=540000`) so the cap survives reboots, and removes it on revert. `BRINGUP/patches/0019-msm-dp-external-rate-cap-parameter.patch` adds the module parameter `a16_dp_max_rate` (kHz, 0 = off, eDP exempt) so the external link rate can be swept at runtime through `/sys/module/msm/parameters/a16_dp_max_rate` plus one re-plug, with no rebuild or reboot per rate. Built on a config-synced copy of the dpnext tree: ABI gate PASS, `task_struct.thread_pid` 2144, symbol CRCs 202 matched / 0 mismatched against 400 kernel-built stock modules, `module_layout` `0xe6658f7b`; srcversion `91CB0186588825FBA8156C6`, sha256 `ad78162b519eab87996055cf163e38df5a144f018c19d4d8fa800e068c1dfa01`, vermagic identical. `sudo bash ~/a16.sh dprate` stages it over the dpnext layer (like `msmlttpr`); `dprate revert` restores. Revert the LTTPR layer first (`sudo bash ~/a16.sh msmlttpr revert`).
- **Prior candidate analysis (historical; superseded by the test below):** the October 1 Glymur combo-PHY v5 series was the latest located upstream and still posted, not merged. It adds rate-specific PCS LN0/LN1 tables at initial clock setup. The isolated QMP v8 training-time PCS refresh was built with matching ABI, then tested; it logged 0x02→0x12→0x16→0x1a but LTTPR1 EQ still failed. Do not stage/retest this same candidate. See `BRINGUP/evidence/2026-10-02-qmp-v5-ln-drive-candidate.txt` and `BRINGUP/evidence/2026-10-02-dpdrive-test-hard-reboot.txt`.
- **Follow-up hotplug capture ended in freeze/reboot (2026-10-02).** User reports no picture after 3–4 plug/unplug cycles, then the machine froze. The already-running watcher preserved `/home/jc/a16-payload/display-outputs-20261002-163318.log` and `.kernel.log`: this attempt used DP-2 (`af5c000`/`fde000.phy`), not DP-1. DP-2 toggled connected/disconnected four times; the captured link ran at 8.1 Gbps ×4, LTTPR1 clock recovery passed but EQ failed `-110`; later downstream (`phy 0`) training phases logged success and stream setup proceeded, then DPU vblank/frame/IRQ timeouts began. Another LTTPR1 retry failed. Reboot boundary verified: prior boot `42967b08-f757-4e86-b128-936f6ae93c28`, current boot `4d9da362-0252-4f40-a2ff-7fd41cdb8aad`; reset initiator unknown. Current loaded modules remain QMP v5 `151CA3C3BDC39CA185C951B` + MSM `BBD010BD47287F02B65EE84`, `dpdrive` absent. No more hotplug cycles. Investigate DP-2's PHY/controller route separately from the prior DP-1 tests; the trace still does not prove Snapdragon-specific residue or a fix. Evidence: `BRINGUP/evidence/2026-10-02-repeated-hotplug-dp2-freeze.txt`.
- **Next MSM candidate BUILT and ABI-verified, not staged (2026-10-02): LTTPR segment training.** Reading the two independent captures together gives the first concrete root-cause candidate for the LTTPR failure: the repeater segment is trained with **TPS4** chosen from a `panel->dpcd` snapshot taken while the LTTPRs were still transparent (sink `DPCD 0x003 = 0x81`, TPS4 bit set), while the same byte reads `0x01` once the LTTPRs are active - and it is TPS3 that the sink segment trains with successfully in the same logs. Separately, requested drive levels were never limited by the repeater's advertised capability (`0xf0021`, which msm never read), and clock recovery collapses exactly when pre-emphasis 3 is forced in. Patch `BRINGUP/patches/0018-msm-dp-lttpr-segment-training.patch` (4 files) scopes TPS4 to the sink segment, reads/stores LTTPR PHY caps, and clamps the requested levels to the advertised maximum while signalling max-reached at that clamp. Built natively (srcversion `9480D61C3303C172B7EE756`, sha256 `babb50b869ee7278936f16a2866c6c315227912a73a811bb3a5e4f5b60051a26`); 805/805 shared symbol CRCs unchanged and the 3 new imports cross-checked against in-tree `xe.ko`. `sudo bash ~/a16.sh msmlttpr` stages it over the dpnext layer for the next boot; `msmlttpr revert` restores the dpnext MSM (do that before `dpnext revert`). Evidence: `BRINGUP/evidence/2026-10-02-msm-lttpr-segment-candidate.txt`. **Staged 16:55 and the boot crashed - not because of this patch.** The module had been built by hand in a copied tree whose `include/generated/autoconf.h` was stale (2026-09-22, missing `CONFIG_DEBUG_INFO_BTF`/`CONFIG_SCHED_CLASS_EXT`), so `task_struct.thread_pid` was read at **1824** instead of **2144** and `get_pid(task_pid())` page-faulted in `msm_gpu_create_private_vm` (three boots, from `gnome-shell`, ~9 s after the GPU bound; that function's disassembly is byte-identical to the working module). This is the 2026-09-17 failure class coming back because the build bypassed `BRINGUP/tools/a16-build-gpucc-native.sh`, whose verifier never ran. Rebuilt on a config-synced tree: ABI verified field by field, `task_struct.thread_pid` now 2144, new sha256 `79bd07cce5fca803d3d6d6f9bb42b637e59b07317fec2a0d23d82862bfd38896`, **srcversion unchanged** (`9480D61C3303C172B7EE756` - it does not change when layouts do). The patch is still untested, and the rollback was still pending at 17:40 EDT. Evidence: `BRINGUP/evidence/2026-10-02-msmlttpr-crash-layout-mismatch.txt`.
- Wi-Fi works with the machine-specific board data and can survive some suspend/resume cycles, but reliability is not established. A later resume showed PCIe Root Port Link Down/recovery failure; `pcie_port_pm=off pcie_aspm=off` is a staged test, not a proven fix. See `BRINGUP/notes/2026-09-30-ath12k-maintainer-handoff.md`.
- Dock USB/ethernet loss after resume and the dark-panel-after-resume behavior remain open. The xHCI patch/initramfs route is not yet proven.
- Internal speakers remain silent; machine-specific audio topology work is blocked/uncertain.
- Bluetooth works via the armed DTB workaround and ROM firmware; making sequencing native and finding the matching rampatch remain optional follow-ups.
- Battery/charge-control unplug/replug behavior still needs a measured confirmation.

`BRINGUP/NEXT-STEPS.md` is the prioritized backlog; dated notes and evidence take precedence over older narrative/history sections below.

**How the machine is configured now:** the **built display driver** option (see
`docs/boot-options.md`) with the Bluetooth device tree armed. Kernel
`7.3.0-rc3-next-20260914`, tree commit `1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`, `acpi=off`.

## Current state (verified on the machine)

| Subsystem | State | Evidence / guide |
|---|---|---|
| Panel / display | **works.** `msm` binds, `card1-eDP-1` connected/enabled, 2880x1800 at **120 Hz and 60 Hz**, backlight `dp_aux_backlight` usable | `docs/display-edp.md`; journal: `link training #2 on phy 0 successful`, `LINK_BW_SET: 0x1e` |
| GPU | device works (`adreno 3d00000.gpu`, GMU fw v5.2.38, `/dev/dri/renderD128`); **mesa rejects the chip id**, so app rendering is software | `docs/gpu-adreno.md`; `MESA: error: fd_pipe_new2:49: unsupported GPU id … chip id 0x18444070041` |
| Internal input | **works** — keyboard, touchpad, touchscreen, stylus, lid | `docs/input.md`; `Asus Keyboard`, `hid-over-i2c 093A:3012`, `04F3:4645` |
| Wi-Fi | **2026-09-22: the radio now survives a suspend** (`patches/0018`, `a16_keep_mhi_up=Y`, in `/etc/modprobe.d/a16-ath12k.conf`) -- but **not every suspend**: measured 11:52 the radio stayed associated (the SSH session was over it), measured 12:29 the same code came back with `wmi command 16387 timeout` for the rest of the boot -- and the difference is now known: that resume's **PCIe link was taken down** ('Recovering Root Port due to Link Down', 'Root Port has been reset', 'AER: can't recover (no error_detected callback)'), so the device was re-initialised behind the driver's back. `pcie_port_pm=off` (+ `pcie_aspm=off`) staged via `sudo bash ~/a16.sh pcielink arm` is the test that keeps the link up; the real fix is PCIe error recovery in ath12k (BRINGUP/notes/2026-09-22-wifi-suspend-ladder.md §9). That difference is the open question now, not the driver-side re-attach. On top: **never unbind the driver after a resume** -- on a wedged MHI the remove path hangs in `mhi_power_down -> flush_work`, and the D-state shell then makes every later suspend fail to freeze. History, kept because it is why the fix looks the way it does — **worked until the first suspend/resume of a boot**, then the firmware stops answering (`failed to resume core: -110` → `wmi command 16387 timeout`). **Measured 2026-09-22: s2idle dies the same way**, so it is ath12k's own resume path and not platform power; unloading ath12k to re-probe it **hangs the machine** (twice), so the reload hook is out. **Fix built and staged: `patches/0014`** — do not SoC-global-reset the device on a resume, so MHI re-attaches to the firmware the suspend deliberately kept (345 imports CRC-checked, `module_layout` `0xe6658f7b`); `sudo bash ~/a16.sh radiofix`, then `wifisleep test`. **No software recovery** — NetworkManager/wpa_supplicant restarts do nothing, unbind/bind leaves the netdev gone, and the module unload froze the machine (2026-09-17). **Root cause narrowed 2026-09-22**: the MHI lines before the timeout are `Power on setup success` → `Wait for device to enter SBL or Mission mode` and then nothing, so after a deep suspend the chip is no longer running firmware and the resume path never re-downloads it (that lives in the probe path). Upstream has **nothing** for this: `ath12k/core.c`, `mhi.c`, `wow.c`, `qmi.c` at linux-next master 2026-09-22 are byte-identical to our tree, and no ath12k suspend patch is in flight (patchwork: newest 2024) | `docs/wifi.md`; `BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt`; `BRINGUP/notes/2026-09-22-wifi-suspend-ladder.md`; **`sudo bash ~/a16.sh wifisleep`** (ladder: `s2idle on`, `hook test`, `hook on`, `forensics`), `reload_wifi`, `lid_sleep` |
| Bluetooth | **works** — controller `3C:EF:A5:29:6A:62` | `docs/bluetooth.md`; runs on ROM firmware, rampatch `hmtbtfw11.tlv` still absent |
| Battery | **works** — upower reports 81.8 %, 95 % health, 42 cycles, conservation mode 75/80 | `docs/power-battery.md` |
| DSPs / audio | **not working** — no internal speaker output; needs a machine ACPI topology | `docs/audio.md`; NEXT-STEPS item 3 |
| Embedded controller | **works (installed 2026-09-22)** — the posted driver (2026-09-17) is applied, built, ABI-verified, installed and bound: `9-0076` → `asus-glymur-ec`, hwmon `asus_glymur_ec` (fans ~1980/1320 RPM, two temperature sensors), keyboard backlight `asus::kbd_backlight` (0–3, default 0 → `ec kbd 2` to light it), event IRQ on gpio66, and the EC now receives suspend entry/exit. It did **not** rescue the radio (s2idle still wedges it) | `BRINGUP/notes/2026-09-22-asus-ec-driver.md`; `BRINGUP/patches/0011..0013`; `sudo bash ~/a16.sh ec status\|build\|install\|verify\|revert` |
| Suspend | **2026-09-22: sleeps, wakes, keeps the radio, and the panel comes back** (`a16_keep_mhi_up=Y` + `a16.sh display hook`). Still open (2026-10-02): a lid-close suspend went in as `s2idle` and **never came back** — the journal ends at `PM: suspend entry`, no exit, hard reset (boot `cfa4f2ff-c099-4483-b966-b7c45f396319`). A resume used to kill the `xhci-hcd.1.auto` controller, so the dock's USB/ethernet needed a reboot; `patches/0010` (the fix for that and for the second-suspend abort) **is the loaded module** since the 2026-10-02 initramfs rebuild, so the abort needs re-testing (`sudo lid_sleep test 2`). New: `sudo bash ~/a16.sh resume` puts a partial resume back together (panel, USB, Wi-Fi soft rungs) and `resume hook install` does it automatically. History — **one suspend per boot sleeps; every later attempt aborts** — the lid is a working `SW_LID` switch and logind suspends on it, but after the resume `xhci-hcd.1.auto` returns `-EINVAL` (`hcd->state != HC_STATE_SUSPENDED`), so a closed lid leaves the machine awake and logind retries every ~33 s; that one suspend's resume also kills the Wi-Fi firmware, so a closed lid costs the radio. **`patches/0010` (patched `xhci-plat-hcd.ko`) is now the loaded module** (the `a16_*` knobs show up in `/sys/module/xhci_plat_hcd/parameters/`; the initramfs was rebuilt after the fix). If a boot ever loses it, re-land it with `sudo bash ~/a16.sh wifisleep xhci persist` (rebuilds the initramfs; the runtime module swap is refused because it crashed the machine), then `sudo lid_sleep test 2` | `docs/suspend.md`; `BRINGUP/notes/2026-09-17-xhci-second-suspend.md`; `sudo bash ~/a16.sh suspendfix`; `BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt`; `sudo lid_sleep`; **`sudo bash ~/a16.sh wifisleep xhci`** |
| External DP / HDMI | **BOTH external outputs work (2026-10-02 evening): the Gigabyte over USB-C DP at 5.4 Gbps on either port, and the MSI over HDMI at 5120x1440.** USB-C DP: with `patches/0019` (`a16_dp_max_rate=540000`, now also a persistent modprobe option) the full sequence trains - LTTPR segment `#1` *and* `#2` (the channel EQ that failed `ret=-110` at 8.1G in every earlier session) plus the sink segment, `LINK_BW_SET 0x14` - hotplug included, with 0 prepare failures and 0 DPU/vblank timeouts; eDP is exempt and keeps HBR3. Everything before that was the rate: the sinks advertise 5.4G in the basic DPCD block (0x00001) but 8.1G in the extended block (0x02200) that `drm_dp_read_dpcd_caps()` merges over it, so the driver trained 8.1G x4 on a link only guaranteed at 5.4G and never down-shifted. The MSI's internal repeater fails channel equalization at *any* rate (DP-1/DP-2 x 8.1G/5.4G all failed) and its failure used to freeze the desktop; over **HDMI** it comes up instead (`card1-HDMI-A-1 connected/enabled @ 5120x1440`, 0 DPU errors) because the HDMI output on the tertiary combo PHY does not pass through that repeater. `patches/0020` drops the stuck DPU `CTL_FLUSH` on a commit-done timeout so a dead sink can no longer wedge the whole desktop (not yet exercised). Open: HDMI refresh rate and hotplug stability, the unexplained first-boot-after-freeze black screen, and whether the permanent form should respect the basic `MAX_LINK_RATE` or add a missing fallback. | `BRINGUP/evidence/2026-10-02-msi-over-hdmi-and-gigabyte-both-ports.txt`; `BRINGUP/evidence/2026-10-02-first-clean-external-dp-at-5g4.txt`; `BRINGUP/evidence/2026-10-02-gigabyte-vs-msi-port-pattern.txt` |
| `efivars` | present (102 entries) | `/sys/firmware/efi/efivars` |
| RAM in the DT boot | 47.6 GiB of 48 GiB | `/proc/meminfo` |

## What changed on 2026-09-22 (the Wi-Fi wedge)

The radio used to die on the first suspend of a boot, with no way back but a reboot. It now survives,
and the reason the earlier attempts failed is understood:

1. **The suspend never takes the device's power or its firmware away.** After a resume the chip is in
   mission mode (MHI state `0x2`) and *refuses* a fresh firmware start with
   `qmi wlan config request failed, result: 1, err: 90` → `-22`. Only a still-running firmware answers
   that way, and that is why `patches/0014`'s "skip the SoC global reset" was right but not enough.
2. **What a suspend destroys is the host side**: `ath12k_core_suspend_late()` →
   `ath12k_hif_power_down(is_suspend=true)` → `mhi_power_down_keep_dev()` + MHI deinit, and nothing
   afterwards can rebuild it — the driver's own re-attach is refused by the running firmware
   (`patches/0015`), and taking the driver off the device and re-probing it dies on the previous
   instance's MHI/QRTR objects (`mhi_queue` oops + `duplicate filename '/bus/mhi/devices/mhi0_IPCR'`).
3. **So don't destroy it.** `patches/0018` (`a16_keep_mhi_up=Y`): the suspend keeps the MHI link, the
   CE/HTC state and the rings exactly as they are (the interrupts still get disabled, so an associated
   radio cannot wake the system straight back up), and the resume re-arms them. Nothing is reset,
   nothing is re-attached, nothing is rebuilt. Measured 2026-09-22 11:52: the resume log is

       A16: suspend -- keeping the MHI link and the device's firmware up
       A16: resume -- the device and the MHI link were left up; re-arming the interrupts
       PM: suspend exit

   with no timeout and the SSH session still up over `wlP4p1s0`.

Two other results from the same day, both on the path to that:

* **`patches/0016`**: a failed resume used to leave the netdev registered with its HAL rings deinited,
  and NetworkManager opening the interface then walked a deinited ring
  (`ath12k_hal_srng_access_begin` oops → RCU stall → machine frozen with no keyboard or touchpad).
  A failed resume now sets `ATH12K_FLAG_CRASH_FLUSH` and degrades to "no WiFi until a reboot".
* **`patches/0017`**: `ath12k_thermal_cleanup_radio()` called the kernel's
  `hwmon_device_unregister()` a second time with NULL (the kernel does not check), which froze the
  machine on every unbind after a failed resume. The cleanup is idempotent now.

Also new: `sudo bash ~/a16.sh display wake` / `display hook` — the first resume left the panel dark
after login (`dp_aux_backlight bl_power=4`, `card1-eDP-1 enabled=disabled`) with the session alive;
`systemctl restart gdm` restored it, and the hook does that by itself, but only when the panel really
is dark.

## What changed on 2026-09-17

1. **The display is solved**, and the fix was the *rate* `msm` picked, not the PHY: the v8 eDP PHY
   sequence is broken for everything except 4-lane 8.1 G, and this panel's advertised rate list
   stops at 5.4 G (HBR2), so `msm` chose the one broken case. `patches/0009` takes the highest rate
   the device tree allows. First successful link: `link_rate=810000`, `LINK_BW_SET: 0x1e`,
   `link training #2 … successful`.
2. **The GPU clock controller** (`CONFIG_CLK_GLYMUR_GPUCC`) is still the prerequisite for `msm` to
   bind at all; the module is built natively and installed into `updates/`.
3. **A build-config mismatch was found and fixed**; it had produced three kernel oopses in three
   unrelated functions. `pahole` missing → kconfig drops `CONFIG_DEBUG_INFO_BTF` → drops `CONFIG_SCHED_CLASS_EXT`
   → `struct task_struct` loses `scx` and every later field shifts by 320 bytes
   (`thread_pid` 1824 in our modules vs 2144 in the kernel) → modules oops at the first
   `get_pid(task_pid(...))`. Two things hid it: `srcversion` does not change when layouts do, and
   `make M=...` never regenerates `include/generated/autoconf.h`. Fixed in
 `BRINGUP/tools/a16-build-gpucc-native.sh` (which now refuses to build without pahole, keeps
 `DEBUG_INFO_BTF` on, and verifies the built module's `thread_pid` offset against the kernel's
 before installation). **2026-10-02: the same class of fault returned** because a hand-rolled
 `make M=...` in a copied tree bypassed that verifier; `BRINGUP/tools/a16-abi-layout-gate.sh
 <tree>` now tests the whole set of kernel-dependent offsets against `/sys/kernel/btf/vmlinux`
 in one command and must PASS before a module from that tree is staged. (The config fix itself lives in `BRINGUP/tools/a16-fix-build-config.sh` - the `scripts/` path this section used to name was wrong.)
4. **Docs restructured around components** (`docs/`, patches embedded verbatim) and a from-scratch
   bootstrap added (`scripts/a16-bootstrap.sh`, `--check` is read-only).
5. **The external-display freeze is diagnosed** (plugging a monitor into USB-C or HDMI). It is the
   combo PHY's clock bundle failing with `-EBUSY` — `gcc_usb3_tert_phy_com_aux_clk` (HDMI, every boot,
   nothing plugged in) and `disp_cc_mdss_dptx1_link_clk` (USB-C DP) — after which `msm` carries on and
   the atomic commit never completes, so gnome-shell's KMS thread blocks in `WAIT_VBLANK` and only the
   picture dies; the kernel keeps running and is reachable over SSH. Evidence and a capture tool are in
   `docs/display-outputs.md`.
6. **Boot default is entry [3]** ("full display attempt"), set with `sudo bash ~/a16.sh default 3`;
   the 30 s menu stays up so [2] remains reachable by hand, and [1] is retired.
7. **The external-display clock blocker is solved** (item 5's clock half, and NEXT-STEPS item 10):
   the tert combo PHY's `gcc_usb3_tert_phy_com_aux_clk` was never stuck because of the PHY — its
   controller domain `gcc_usb30_tert_gdsc` was simply never powered, since this board's only DT
   consumer for it is the USB controller on the HDMI/DP PHY, which is disabled and (when enabled)
   defers on that same PHY. Forcing the domain on from a consumer that always binds — one
   `power-domains` specifier on `/hdmi-bridge`, which is what `genpd_dev_pm_attach()` powers at
   attach — gives `gcc_usb30_tert_gdsc = on` and a boot log with no `com_aux`, `phy init failed` or
   `dptx1_link_clk` line at all. Staged with `sudo bash ~/a16.sh tertphy arm bridge` (revert with
   `tertphy revert`); the proper form is a machine-DTS change. Evidence:
   `BRINGUP/evidence/2026-09-17-tertphy-domain-check.txt`.
8. **The lid and the Wi-Fi wedge are the same event, and both are now tools**: the lid *does* suspend,
   and the first suspend of a boot sleeps — after the resume, every later attempt aborts on
   `xhci-hcd.1.auto` (`-EINVAL` from `xhci_suspend()`, `hcd->state != HC_STATE_SUSPENDED`) and logind
   retries it every ~33 s while the lid is shut, so a closed lid leaves the machine awake at ~6-7 W
   (10 %/h). The same resume is where `ath12k` loses its firmware (`failed to resume core: -110`, then
   `wmi command 16387 timeout` for the rest of the boot), which is what made Wi-Fi look like an idle
   problem. Both findings have a console command: `sudo reload_wifi` (diagnose, the two soft rungs,
   then the verdict) and `sudo lid_sleep` (state, a reproducible two-attempt test, and the lid policy).
9. **The lid's real blocker is diagnosed and a fix is staged** (the drain of item 8): the second and
    every later suspend of a boot aborts because `xhci_suspend()` finds `hcd->state` (or the shared
    HCD's) not `HC_STATE_SUSPENDED` — the USB core never left the root hubs suspended for
    `xhci-hcd.1.auto` (`a400000.usb`, the instance with the internal USB mass storage device;
    `xhci-hcd.2.auto` is fine). The platform callback's `-EINVAL` fails the *whole system suspend*,
    which is why one controller costs the machine its sleep. `patches/0010` puts the workaround in
    `xhci-plat-hcd.ko` (the only module on that path): leave the controller running, skip the matching
    resume, and log the hcd/root-hub states. Built natively, ABI-verified (62 imports identical,
    `module_layout` 0xe6658f7b), installed with `sudo bash ~/a16.sh suspendfix`; `lid_sleep test 2`
    after the reboot is the verification, and the A16 lines in its log name the root cause
    (`BRINGUP/notes/2026-09-17-xhci-second-suspend.md` has the three candidates).
10. **The recovery ladder was run on a real wedge (boot `e090779e`, 15:09–15:12) and the radio cannot be
   recovered from software**: restarting NetworkManager/wpa_supplicant does nothing, unbind/bind
   (`ath12k_wifi7_pci`) leaves the netdev gone, and the module unload **froze the whole machine** and
   needed a hard reset. `reload_wifi` therefore runs the harmless rungs by default and puts the four
   driver-teardown rungs behind `A16_I_KNOW=1`; the honest answer for a wedged radio is a reboot. What
   works is prevention: the wedge lands on the resume of the one suspend per boot that completes, so
   `sudo lid_sleep lid ignore` (a closed lid is inert) keeps the radio alive at the cost of never
   sleeping. Evidence: `BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt`.

## What changed on 2026-09-22

Reported: "the Wi-Fi still shuts off if it goes to sleep and I have to restart". Four results.

1. **The radio's death is now pinned to a line.** The MHI messages immediately before the resume
   timeout are `Power on setup success` → `Wait for device to enter SBL or Mission mode`, and then
   nothing: after a deep suspend the QCC2072 is no longer running its firmware, and the resume path
   resets the chip and asks MHI to power it up without ever re-downloading firmware (that lives in the
   probe/QMI flow). A reboot fixes it *because a reboot is a probe*. This also re-frames the
   2026-09-17 ladder result: the unbind/bind failure and the freeze happened on a device already in
   that state, not on a healthy radio.
2. **Upstream has nothing to bring in for this.** File-by-file against linux-next master 2026-09-22:
   `ath12k/core.c`, `mhi.c`, `wow.c`, `qmi.c`, `wifi7/pci.c`, `usb/host/xhci*.c`, `usb/core/*`,
   `base/power/main.c` and this machine's DTS are **identical** to our tree; no ath12k suspend/resume
   patch is in flight (patchwork, newest 2024). The only deltas are ath12k's ASPM rewrite (needs the
   new `pci_force_enable_link_state()` API, not a suspend fix) and a hw-ops rename tied to a mac80211
   API change. The one new upstream item for our chip is firmware-side: linux-firmware 2026-09-21
   updated `ath12k/QCC2072/hw1.0/board-2.bin`.
3. **`patches/0010` has never actually run.** The patched `xhci-plat-hcd.ko` is installed and
   `modules.dep` prefers it, but the loaded module is the **stock** one (srcversion `B815AC50…`, no
   `a16_*` parameters) because the module is loaded from the initramfs copy, and
   `/boot/initrd.img-7.3.0-rc3-next-20260914` was built 2026-09-16 13:15, before the fix existed. So
   the second-suspend abort has never been tested with the fix: it was not "staged", it was inert.
   `sudo bash ~/a16.sh wifisleep xhci` lands it for the current boot (module swap);
   `… xhci persist` rebuilds the initramfs for good (backup + file-list verification first).
4. **The machine's EC driver was posted on 2026-09-17 and is now built here** (see the table row
   above and `notes/2026-09-22-asus-ec-driver.md`): fans, two temperature sensors, keyboard backlight,
   sideband events — and suspend entry/exit notification to the EC, which this machine has never
   done. That is the platform-level suspect for the module losing power across a suspend, and the
   cheapest one to test.

Two new console tools, both in the established one-line form:

    sudo bash ~/a16.sh wifisleep            # the sleep/radio ladder: s2idle, the reload hook, the xhci fix
    sudo bash ~/a16.sh ec status|build|install|verify|revert    # the EC driver

5. **The ladder was then run on the machine, and three doors closed** (same day): s2idle kills the
   radio exactly like deep suspend → ath12k's own resume path, not platform power; `modprobe -r
   ath12k_wifi7 ath12k` **hangs the machine on a healthy radio** (the 2026-09-17 freeze was not about
   the wedge) → the reload hook is out; the xhci module swap verified and then the next resume left a
   black screen → the fix must land in the initramfs. The EC driver, installed in the same run, binds
   and gives fans/temperatures/keyboard backlight, but did not rescue the radio.
   `BRINGUP/evidence/2026-09-22-ladder-runs.txt`.
6. **`patches/0014` + `0015` are the lever that is left**: the resume used to run the WiFi SoC's global reset
   (`ath12k_pci_power_up()` → `ath12k_pci_sw_reset()`), throwing away the firmware that
   `mhi_power_down_keep_dev()` had deliberately kept, and nothing re-downloaded it. The patch marks a
   resume (`ATH12K_FLAG_A16_RESUMING`), skips the reset there, and logs both MHI states.  **Ran on the
   machine 2026-09-22 09:28: the device came back in MHI M0 (0x2) with its firmware running** — the
   "no firmware at all" failure is gone — but nothing announced a restart, so the driver's own 20 s
   wait expired and left the radio half-attached.  `patches/0015` finishes it: a device that was kept
   is re-attached through the firmware-crash recovery path instead of being waited for.  **The same
   resume killed `xhci-hcd.1.auto` ("HC died; cleaning up"), which took the dock's ethernet with it** —
   a second, separate fault (same controller as the second-suspend abort); until it is understood, do
   not suspend (`sudo lid_sleep lid ignore`).  Evidence: `evidence/2026-09-22-ladder-runs.txt` §5.

Also fixed while here: the tools no longer filter the kernel log by timestamp (`--since` is unusable
on this machine — no RTC, so kernel lines carry the pre-NTP date); they slice the log by boot offset
instead.

## Open work

`BRINGUP/NEXT-STEPS.md`, one item at a time. The order that makes sense now:

0. **ONE line, run it over SSH as often as needed** (2026-09-22, after the ladder was run): the EC is
   installed and working, the reload hook and the xhci module swap are both out (they hang or
   black-screen this machine), and s2idle is answered (the radio dies anyway). What is left is
   `patches/0014` (no SoC reset on resume), and the whole sequence is now one command that works out
   which step it is in.  **One trap cost a restart on 2026-09-22**: a locally rebuilt module's
   *exported* symbol CRCs differ under gcc 15.3 (this machine) from the kernel's build (gcc 15.2), so
   `ath12k_wifi7` refused our `ath12k.ko` and the radio had no driver; the export table is now
   transplanted from the kernel's own module and verified after every build
   (`notes/2026-09-22-wifi-suspend-ladder.md` §7):

       sudo ~/a16step          # or: sudo bash ~/a16step.sh

   1st run installs the fix and says "start again into [3]"; after the restart the same line starts
   the suspend test detached (an SSH drop at the suspend cannot lose it); the same line afterwards
   prints the verdict.  `sudo ~/a16step status|verdict|log` are read-only; `xhci` lands the
   second-suspend fix in the initramfs once the Wi-Fi question is settled.  Results of the first run:
   `BRINGUP/evidence/2026-09-22-ladder-runs.txt`.

1. **Bluetooth, source-level DT patch** — the working change is a diff against the decompiled DTB;
   the same change against `glymur-asus-zenbook-a16-ux3607oa.dts` is the only piece of the BT work that is not yet
   in a form that can be applied directly. `docs/bluetooth.md` says what it needs.
2. **Upstream the display fix** — either by feeding this machine's data to the posted v8 PHY series
   (it does not cover 4-lane 5.4 G, which is exactly what this panel uses) or by making the usable
   rate explicit for this PHY revision. `docs/display-edp.md` has the details.
3. **Audio**: a machine ACPI topology for the WSA884x speakers (biggest remaining win, upstream work).
4. Battery verification across AC/battery. 5. **Suspend/resume: why `xhci-hcd.1.auto` refuses the
second suspend** (the lid's real problem). 6. Bluetooth rampatch name mismatch.
7. **Wi-Fi: the profile/BSSID behaviour** (the wedge itself is understood and not fixable: reboot, or
`lid_sleep lid ignore` to avoid it — it stops when the resume path is fixed).
8. ACPI-mode input match tables (optional).
9. Housekeeping: keep `notes/` current; `BRINGUP/tools/a16-grub-dedupe.sh` still has not been run
   (a duplicate menu entry physically remains in the four ESP configs).

## Known issues / blocks

- **Input cannot work in ACPI mode.** `ACPI\QCOM0F10` (I2C) and `ACPI\QCOM0F0C` (GPIO) match no
  linux-next driver, so no I2C adapter appears and the firmware I2C-HID children never enumerate.
  The DT boot is the route.
- **The pinned upstream DTS cannot be dropped in.** Qualcomm platforms expect the *firmware's* DT in
  the UEFI configuration table with the Linux DTB applied on top; GRUB's `devicetree` replaces it, so
  a bare upstream DTB boots with no RAM and no console. The bring-up boots the machine DTB and
  patches it instead. (Upstream's A16 DTS does exist and builds byte-identical to the machine's stock
  DTB.)
- **Two DTB files are overwritten by design** (`/boot/glymur-…dtb` and its ESP twin), stock copies
  kept as `*.a16stock`; the working and stock blobs are also kept in `firmware/`. A kernel or grub
  update can stomp them.
- **Fn/media keys** need the pending `HID: asus` patch for keyboard `0B05:4B42`; typing works without
  it. With `acpi=off` there is no EC driver, so brightness Fn keys do not exist as input devices —
  the desktop slider is the way to change brightness.
- **The built modules are unsigned and our own**: `CONFIG_MODULE_SIG_FORCE` is not set, so they load
  and taint the kernel. They must be rebuilt whenever the kernel changes, and the config/ABI check
  must pass first.

## Machine paths and pins

- **On the machine:** repo `/home/jc/A16Build`; scripts and every log in `/home/jc/a16-payload/`;
  per-boot reports on the ESP (`/boot/efi/a16-reports/`); the ESP boot payload in
  `/boot/efi/a16boot/`; the build tree in `~/build/linux-next-1a1de54f7369/`.
- **Kernel pin (build side):** linux-next `3d08ff75a47a3e7e2ab45a3bcab6723b4d906422`
  (`7.2.0-rc7-next-20260810`). The **installed bundle** is `7.3.0-rc3-next-20260914`
  (`zenbook-a16-7.3.0-rc3-next-20260914.tar.zst`, 195 503 048 B, sha256 `2cb362c2…`).
- **Helper scripts:** `scripts/a16-bootstrap.sh --check` (whole-machine state),
  `BRINGUP/tools/a16-gpu-fix.sh` (`~/a16.sh`; install → verify → start the desktop),
  `BRINGUP/tools/a16-bt-setup.sh status` (which DTB is live),
  `BRINGUP/tools/a16-wifi-recover.sh` (**`reload_wifi`**; the recovery ladder for the firmware wedge),
  `BRINGUP/tools/a16-sleep-test.sh` (**`lid_sleep`**; the lid, and whether a suspend works),
  `BRINGUP/tools/a16-wifi-sleep.sh` (**`wifisleep`**; s2idle vs deep, the reload-across-suspend hook,
  landing the xhci fix, post-wedge forensics),
  `BRINGUP/tools/a16-ec.sh` (**`ec`**; the ASUS EC driver: build / install / verify / kbd / revert),
  `BRINGUP/tools/a16-step.sh` (**`a16step`**, also `~/a16step.sh`; **the whole Wi-Fi/sleep job as one
  command over SSH** — install the fix, run the suspend test detached, print the verdict),
  `BRINGUP/tools/a16-install-ath12k-resume-fix.sh` (**`radiofix`**; patches/0014 install/build/revert),
  `BRINGUP/tools/a16-install-console-commands.sh` (installs both as `/usr/local/bin` symlinks),
  `BRINGUP/tools/a16-boot-snapshot.sh` (per-boot evidence).
- **ABI gate:** `BRINGUP/tools/a16-abi-layout-gate.sh <kernel-tree>` — compares the tree's headers
  against the running kernel's BTF struct offsets (`task_struct` and friends) and fails loudly;
  run it before building or staging any module, especially from a copied tree.
- **Archive:** everything before this era is in `archive/2026-09-16-pre-bringup/`, whose README
  indexes the ISO builders, the ESP staging/bootloader work, the harvest, the old PLANS and the old
  STATUS.

