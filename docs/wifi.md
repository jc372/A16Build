# Wi-Fi — `ath12k` (Wi-Fi 7)

**State: Wi-Fi works with the A16-specific board data; suspend/resume remains experimental — and the
wedge tracks *repeated* suspends: the first suspend of a boot keeps the radio, later ones cost it
(measured 2026-10-02, see below).**
The machine uses a locally assembled `board-2.bin` because the distro image lacks a matching
board-data key, and the file has to be rebuilt from your own Windows WLAN package — see
[firmware.md](firmware.md). Downstream ath12k resume patches have been tested, but PCIe link loss can
still leave the radio wedged. See the [current maintainer handoff](../BRINGUP/notes/2026-09-30-ath12k-maintainer-handoff.md)
and the [A16 board-data provenance](../retired/firmware/ath12k-board-2-qcc2072-e14f/README.md).

## Current status and maintainer handoff

- [Kernel.org Bug 221984: QCC2072 board file for ASUS Zenbook A16](https://bugzilla.kernel.org/show_bug.cgi?id=221984)
- [A16 maintainer handoff note](../BRINGUP/notes/2026-09-30-ath12k-maintainer-handoff.md) — identifiers, current evidence, what upstream still needs, and a draft reply.
- [Suspend/PCIe analysis](../BRINGUP/notes/2026-09-22-wifi-suspend-ladder.md#9-why-one-resume-kept-the-radio-and-the-next-did-not-2026-09-22) — separate issue; the link-preservation experiment is not yet a proven fix.

## The hardware

| | |
|---|---|
| Driver | `ath12k` (also `ath12k_wifi7`) |
| Board data | the board file the driver expects is present in the firmware package; see `notes/2026-09-16-hermes-wifi-board-data.md` |
| Interface | `wlP4p1s0`, managed by NetworkManager |

## The failure: the firmware stops answering after a suspend

**State: reproduced, and it is a resume problem, not an idle problem.** Reported from the console on
2026-09-17 as "closing the lid, or leaving the machine for a while, disconnects Wi-Fi and it cannot
find a network again until reboot"; the log says the radio's firmware stops answering on the resume of
the one suspend per boot that completes (see [suspend.md](suspend.md)):

    kernel: ath12k_wifi7_pci 0004:01:00.0: timeout while waiting for restart complete
    kernel: ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110
    kernel: ath12k_wifi7_pci 0004:01:00.0: PM: failed to resume async: error -110

From then on the WMI (firmware command) channel is dead for the rest of the boot, and the interface
cannot be brought up at all — which is what the desktop shows as an empty network list, with the radio
still listed in Settings:

    kernel: ath12k_wifi7_pci 0004:01:00.0: wmi command 16387 timeout                (repeating)
    kernel: ath12k_wifi7_pci 0004:01:00.0: failed to send WMI_PDEV_SET_PARAM cmd
    kernel: ath12k_wifi7_pci 0004:01:00.0: fail to start mac operations in pdev idx 0 ret -11
    wpa_supplicant: wlP4p1s0: Could not set interface 'wlP4p1s0' UP: Resource temporarily unavailable
    wpa_supplicant: wlP4p1s0: Failed to initialize driver interface
    NetworkManager: device (wlP4p1s0): supplicant interface keeps failing, giving up

`-11` is `EAGAIN` relayed from the firmware channel, so it is not a permissions, profile or board-data
problem, and restarting NetworkManager alone does not fix it: the wedge is below it. Two boots on
2026-09-17 show the same sequence (`20167034`, `3a63a313`), both on resume. Evidence:
`BRINGUP/evidence/2026-09-17-lid-suspend-wifi-wedge.txt`.

## There is no software recovery from the wedge: reboot

Measured on 2026-09-17, boot `e090779e` (`~/a16-payload/wifi-recover-20260917-150949.log`):

| what was tried | result |
|---|---|
| restart NetworkManager | no effect — the interface stays `unavailable` (the firmware never answers) |
| restart wpa_supplicant + NetworkManager | no effect, and the command cannot put the interface up either |
| unbind / bind `ath12k_wifi7_pci` | unbind succeeds and the netdev disappears; the bind does **not** bring it back (45 s, no netdev, no probe) |
| unload the modules (`modprobe -r ath12k_wifi7 ath12k`) | **the whole machine froze** inside the unload and needed a hard reset — this is the log's last line |

So `reload_wifi` runs the two harmless rungs and then says so plainly, and the four driver-teardown
rungs (PCI function reset, unbind/bind, PCI remove + rescan, module reload) are behind
`A16_I_KNOW=1 sudo reload_wifi hard` — they are the normal way to reset a *healthy* driver, but they do
not recover this wedge and two of them are worse than the wedge. Both commands answer `--help`.

    reload_wifi --help                 # this, and every mode
    reload_wifi status                 # read-only, no root: which state the radio is in
    sudo reload_wifi                    # the two soft rungs, then the verdict
    A16_I_KNOW=1 sudo reload_wifi hard  # the four driver rungs (see the table above first)
    sudo lid_sleep lid ignore           # the thing that actually avoids the reboot

Log: `~/a16-payload/wifi-recover-<timestamp>.log`.

## What keeps the radio alive: do not let the lid suspend

The wedge lands on the resume of the one suspend per boot that completes, so a closed lid is what costs
the radio — and today a wedged radio costs a reboot. `sudo lid_sleep lid ignore` makes a closed lid
inert (logind stops suspending and stops retrying every ~33 s), which keeps the radio and gives up
sleeping entirely. That is the trade this machine offers until the suspend path is fixed:
[suspend.md](suspend.md).

## Verify

    nmcli device status
    ip -brief addr show wlP4p1s0
    journalctl -k -b 0 -o cat | grep -i ath12k | tail

### 2026-10-02 late: which resume path can keep the radio (the `a16_keep_mhi_up` question)

Our ath12k patch carries two resume paths, and the one installed since 2026-09-22 is the one the evidence
argues against:

* **`a16_keep_mhi_up=Y` (installed)** — `ath12k_core_suspend_late()` leaves the MHI link and the device's
  firmware up, and `ath12k_core_resume_early()` re-enables the interrupts, completes `restart_completed` and
  returns success **without touching the firmware at all**. Every measured resume under it leaves the firmware
  unresponsive: `wmi command 16387 timeout`, `failed to enable PMF QOS: -11`, `fail to start mac operations in
  pdev idx 0 ret -11`, interface never comes up.
* **`a16_keep_mhi_up=0`** — the HAL takes the MHI link down with `mhi_power_down_keep_dev()` (device and
  firmware deliberately kept, which is what `a16_skip_global_reset_on_resume=Y` exists for), and the resume
  re-attaches MHI and then, seeing `ATH12K_FLAG_A16_KEPT_DEVICE`, queues the **firmware-crash recovery path**
  (`ath12k_core_reconfigure_on_crash()` → `ath12k_core_qmi_firmware_ready()` → `ath12k_core_start()`): a fresh
  HTC/WMI handshake with the firmware that is still running. That is what the failing resumes appear to need —
  the device is up (M0) and simply never answers afterwards.

So the next radio experiment is a configuration change, not a build:

    sudo bash ~/a16.sh radiofix                    # write only a16_skip_global_reset_on_resume=Y
    # reboot, then suspend/resume, then:  sudo reload_wifi status ; sudo bash ~/a16.sh resume_log
    sudo bash ~/a16.sh radiofix install keepmhi    # to put a16_keep_mhi_up=Y back

Read the result as: **radio survived** → the re-attach is the answer and this becomes the default; **still
wedged** → the firmware itself does not survive the platform's suspend (not just the host side), and the work
moves to what the suspend does to the device's power/clock state.

**Measured 2026-10-02 23:24, boot `01bd23bd` (s2idle, lid): still wedged.** `ath12k_wifi7_pci 0004:01:00.0:
failed to resume core: -110` and `PM: failed to resume async: error -110`, with nothing from the driver
afterwards — so the re-attach path does not complete either. Decisively, the **same resume pass also failed a
non-Wi-Fi device**: `dwc3-qcom a600000.usb: PM: failed to resume: error -110`. This is therefore a
platform-level resume problem, not the Wi-Fi driver's alone. The Wi-Fi hardware is healthy afterwards
(0x17cb:0x1112, link 8.0 GT/s x1, D0, driver bound, `wlP4p1s0` present), so what is wedged is firmware state,
and there is **no reboot-free recovery** from it (see the `reload_wifi` ladder — rungs 1/2 no effect, rung 3's
bind does not return the radio, h3/h4 go through the same remove path and h4 freezes the machine). Leading
suspect for the common cause: the platform's clock/interconnect providers never finish `sync_state()` because
`1dfa000.crypto` and `3d6c000.gmu` never probe. Evidence:
`BRINGUP/evidence/2026-10-02-s2idle-keepmhi0-radio-still-dies-usb-too.txt`.

## Related

Bluetooth shares the combo chip but is a separate driver path and a separate bring-up; see
[bluetooth.md](bluetooth.md).

## 2026-10-02: the wedge tracks repeated suspends, and the MHI channel fails first

Three suspends in one boot (`d92a3795`): the **first** resumed with the radio intact and working
(`NetworkManager: device (wlP4p1s0) … Activation: successful`, EHT 576/864 Mbit/s). The **second** and
**third** left it dead — `wmi command 16387 timeout` every ~13 s, `failed to enable PMF QOS: -11`,
`fail to start mac operations in pdev idx 0 ret -11`. `a16_keep_mhi_up=Y` was active and said so (the
`A16: suspend -- keeping the MHI link and the device's firmware up` / `A16: resume …` lines are
patches/0014 doing its job); the radio died anyway.

The new detail is the line that precedes the WMI timeouts, and it appears only on the later resumes:

    qcom_mhi_qrtr mhi0_IPCR: failed to prepare for autoqueue transfer -5
    qcom_mhi_qrtr mhi0_IPCR: PM: dpm_run_callback(): qcom_mhi_qrtr_pm_resume_early [qrtr_mhi] returns -5
    qcom_mhi_qrtr mhi0_IPCR: PM: failed to resume early: error -5

So the open question is the MHI/QRTR resume path — why the autoqueue transfer cannot be prepared the
second time round — and the practical rule until it is fixed is **one suspend per boot**: a single lid
close/open keeps the radio; a second suspend costs it. A wedged radio has no software route back
(`reload_wifi --help`: the module reload froze the machine), so that is a reboot.

Evidence: `BRINGUP/evidence/2026-10-02-repeated-suspend-wedges-radio.txt`.
