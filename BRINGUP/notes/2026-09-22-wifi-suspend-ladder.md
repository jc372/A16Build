# 2026-09-22 — Wi-Fi across a suspend: what upstream has, what our own fix was doing, and the ladder

Written after the report "the Wi-Fi still shuts off if it goes to sleep and I have to restart".
Two questions were asked: (1) has anything landed upstream that we should bring in, (2) fix it.

Everything below is measured on the machine (kernel `7.3.0-rc3-next-20260914`, tree commit
`1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`, boot `f5013e6c`) and against linux-next master,
the wireless tree, patchwork and linux-firmware as of 2026-09-22.

## 1. The device, and the path that fails

    $ lspci -nn -s 0004:01:00.0
    0004:01:00.0 Network controller [0280]: Qualcomm Technologies, Inc Device [17cb:1112] (rev 01)

`17cb:1112` is **QCC2072** (`wifi7/pci.c`: `#define QCC2072_DEVICE_ID 0x1112`), and its hw params
entry is `qcc2072 hw1.0` (`wifi7/hw.c:718`) with **`.supports_suspend = true`** and
`.mhi_config = &ath12k_wifi7_mhi_config_wcn7850`.  Because `supports_suspend` is true, the driver
takes part in system suspend:

* suspend: `ath12k_core_suspend()` → `ath12k_core_suspend_late()` → `ath12k_hif_power_down(ab, true)`
  → `ath12k_mhi_stop(ab_pci, is_suspend=true)` → `mhi_power_down_keep_dev()`
* resume: `ath12k_core_resume_early()` → `ath12k_hif_power_up(ab)` → `ath12k_pci_power_up()`
  (which **resets the chip**: `ath12k_pci_sw_reset(ab, true)`, then `ath12k_mhi_start()`), then
  `ath12k_core_resume()` waits `ATH12K_RESET_TIMEOUT_HZ` (20 s, core.h:63) for
  `ab->restart_completed`.

`ab->restart_completed` is completed in exactly two places: `ath12k_core_suspend()` (core.c:159, so a
suspend that never powers down does not hang its resume) and `ath12k_core_restart()` (core.c:1680,
the firmware-crash recovery worker).  Nothing completes it on a resume in which the firmware has
gone — so the resume ends the only way it can:

    ath12k_wifi7_pci 0004:01:00.0: timeout while waiting for restart complete
    ath12k_wifi7_pci 0004:01:00.0: failed to resume core: -110
    ath12k_wifi7_pci 0004:01:00.0: PM: failed to resume async: error -110

### The new detail: what the device was doing meanwhile

The MHI lines immediately before those (previous boot, 2026-09-17 15:49:16) are the finding of this
session:

    kernel: mhi mhi0: Requested to power ON
    kernel: mhi mhi0: Power on setup success
    kernel: mhi mhi0: Wait for device to enter SBL or Mission mode      <- and no line after it

The host asked MHI to power the device up, the device came up in **neither SBL nor mission mode**,
and nothing booted it: the firmware download (BHI/AMSS + the QMI handshake) lives in the probe path,
not in the resume path.  So the chip is left sitting in a reset state for the rest of the boot, every
WMI command times out (`wmi command 16387 timeout`, `fail to start mac operations in pdev idx 0
ret -11`), and the interface cannot be brought up — while a **reboot** fixes it, because a reboot is a
probe, and a probe downloads the firmware.

This also reframes the 2026-09-17 recovery ladder result: unbind/bind left no netdev and the module
unload froze the machine *on a device in that state*.  It does not prove that a driver reload is
dangerous in general — which is what `wifisleep hook test` now measures, on a healthy radio.

## 2. "Anything new upstream we should bring in?" — for this path, no

Checked file-by-file against linux-next master (fetched 2026-09-22), not by date:

| file | vs our tree |
|---|---|
| `ath12k/core.c` (suspend/resume/restart) | **identical** |
| `ath12k/mhi.c` (`ath12k_mhi_suspend/resume/stop`) | **identical** |
| `ath12k/wow.c` | **identical** |
| `ath12k/qmi.c` | **identical** |
| `ath12k/wifi7/pci.c` (device table) | **identical** |
| `ath12k/pci.c` | differs: the ASPM handling was rewritten to use `pci_disable_link_state()` / `pci_force_enable_link_state()` ("wifi: ath12k: Use pci_{enable/disable}_link_state() APIs…", landed in ath-next, merged into linux-next 2026-09-21) |
| `ath12k/wifi7/hw.c` | differs: `.set_rx_link_id` renamed to `.get_rx_link_id`, tied to the mac80211 RX API change (`wifi: mac80211: change public RX API to use link stations`, 2026-09-16) |
| `drivers/usb/host/xhci-plat.c`, `xhci.c`, `xhci-hub.c`, `usb/core/*`, `base/power/main.c` | identical (so the second-suspend abort has no upstream fix either) |
| `arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dts` | identical (we are current) |
| `glymur.dtsi` | +10 lines of `dma-coherent` on the four `usb@…` nodes, all `status = "disabled"` on this board |
| `drivers/pci/controller/dwc/pcie-qcom.c` | ASPM-enable no longer forces downstream devices to D0, plus an `iommu-map` parsing rewrite |
| `drivers/pci/pcie/aspm.c`, `include/linux/pci.h` | the new `pci_force_enable_link_state()` API (what the ath12k ASPM commit needs) |

And in flight: patchwork `linux-wireless`, `q=ath12k suspend` — the newest suspend-related ath12k
patches are from **2024** (`fix soft lockup on suspend`, `support suspend/resume`, `change
supports_suspend to true for WCN7850`).  Recent ath12k patches are MAC-address pools, EHT probe
caps, rproc IRQ leaks, `wake_tx_queue` flow control — none of them this.

**Conclusion:** no released or posted ath12k fix exists for this failure, and the two upstream deltas
we lack cannot be taken in isolation anyway (the ASPM commit needs the new PCI API and is not a
suspend fix; the hw.c rename needs the mac80211 RX API change).  The only *new* thing upstream for
our exact chip is firmware-side: **linux-firmware 2026-09-21, `ath12k: QCC2072 hw1.0: update
board-2.bin`** — a board-data update for our part, worth knowing about (see §4).

## 3. Our own staged fix was never running

`patches/0010` (patched `xhci-plat-hcd.ko`, installed 2026-09-17 with `sudo bash ~/a16.sh suspendfix`)
is on disk, and `modules.dep` prefers it:

    $ modprobe -n --show-depends xhci-plat-hcd
    insmod /lib/modules/7.3.0-rc3-next-20260914/updates/a16/xhci-plat-hcd.ko

but the **loaded** module is the stock one:

    $ cat /sys/module/xhci_plat_hcd/srcversion          -> B815AC5012DC9B68AE787AF   (stock)
    $ modinfo -F srcversion …/updates/a16/xhci-plat-hcd.ko -> 0B4B259A2DBD385DF8BAE78 (ours)
    $ ls /sys/module/xhci_plat_hcd/parameters/           -> (empty: no a16_* parameters)

The copies differ in the initramfs: `/boot/initrd.img-7.3.0-rc3-next-20260914` was built
**2026-09-16 13:15**, before the patched module existed, and it is the initramfs copy that udev loads
during the initramfs stage — the stock module is therefore already resident before `/lib/modules` is
consulted, and the fix never runs.  So the second-suspend abort has never been tested with the fix:
the honest state was not "staged", it was "inert".

`wifisleep xhci` lands it for the current boot (module swap; the USB devices re-enumerate) and
`wifisleep xhci persist` rebuilds the initramfs with a backup and a file-list verification.

## 4. Notes on the other two "new" items

* **board-2.bin (QCC2072 hw1.0, linux-firmware 2026-09-21).** Our board data is not upstream's: this
  machine's stock `board-2.bin.zst` has no BDF for subsystem `105B:E14F`, so a converted
  Windows-driver-store board file was built and installed (526 972 B, `board-2.bin`, original kept as
  `board-2.bin.zst.a16bak`; source in `firmware/ath12k-board-2-qcc2072-e14f/`).  Upstream's new file
  is 526 720 B.  Whether the new upstream file now carries a board that matches this machine (which
  would let us drop the hand-built one) is a small, separate experiment: the radio works today, so
  nothing here is urgent, but a board-data update is the one firmware-side change since 2026-08-31
  that touches our exact chip.  Our `firmware-2.bin` *is* current: `fw_build_id
  WLAN.COL.1.0.c2-00277-QCACOLSWPL_V1_TO_SILICONZ-1` matches linux-firmware's 2026-08-31 update.
* **PCIe ASPM (upstream, 2026-09-21).** `qcom_pcie_enable_aspm()` no longer forces downstream devices
  to D0, and ath12k saves/restores ASPM through the PCI API instead of poking `LNKCTL`.  This chip's
  params have `.supports_aspm = false`, so ath12k never enables ASPM on it — the change is unlikely to
  matter, and it cannot be applied without the new `pci_force_enable_link_state()`.

## 5. The ladder, as a tool

`BRINGUP/tools/a16-wifi-sleep.sh`, reached as `sudo bash ~/a16.sh wifisleep …` (one short line at the
console).  It changes nothing by itself in its default mode; each mode prints its verdict.

| step | command | the question it answers | if it is the last one that works |
|---|---|---|---|
| 0 | `wifisleep` | state: sleep mode, hook, whether the patched xhci is really loaded, radio state | — |
| 1 | `wifisleep test` | baseline: does the radio survive *deep* (it does not, per `evidence/2026-09-17-…`) | — |
| 2 | `wifisleep s2idle on` then `test` | is it the platform's deep-suspend power (chip reset) or ath12k's own resume sequence? s2idle runs the same driver callbacks with the platform still powered | persist s2idle — real sleep, radio kept, no build |
| 3 | `wifisleep hook test` | is a driver reload safe on a healthy radio? (the unload is what froze the machine on a wedged one) | — |
| 4 | `wifisleep hook on` then `test` | does unloading ath12k before the suspend and re-probing after it keep the radio? (the probe downloads the firmware the resume path skips, §1) | the hook is the fix — real sleep, radio back in seconds |
| 5 | `wifisleep xhci` / `xhci persist` | the second-suspend abort: land patches/0010 for this boot / for good | every suspend of a boot sleeps |
| — | `wifisleep forensics` | on the next wedge: is the endpoint still on the bus (platform kept power → firmware/MHI fault) or gone (platform powered it off → no driver fix reaches it), and does a PCI reset + rebind recover it without a reboot | a wedge becomes one command instead of a reboot |

Order matters: 2 before 4 (cheapest, no build, and it separates the two candidate causes), and
`hook test` before `hook on` (the unload is the step that froze the machine once).

Deliberately **not** in the ladder yet, in case the hook is what lands: a driver change ("on a resume
timeout, do what the probe does: full power cycle + firmware download" — `ath12k_core_restart()`
already implements that for firmware crashes).  That is a patch to `ath12k.ko`, builds here natively,
and is the right follow-up if reloading by hand works but a permanent hook is not wanted.

## 6. What the first run of the ladder showed (2026-09-22, the same morning)

Full excerpts: `BRINGUP/evidence/2026-09-22-ladder-runs.txt`.  Four results, and three of them close a
door:

| step | result | what it settles |
|---|---|---|
| `s2idle on` + `test` | **the radio died anyway**, same wedge (`wmi command 16387 timeout`) | s2idle runs the same driver callbacks with the platform powered, so the fault is **ath12k's own resume path**, not the platform powering the module down |
| `hook test` | **the machine hung** at `modprobe -r ath12k_wifi7 ath12k`, healthy radio | unloading ath12k is not a usable lever on this kernel; the 2026-09-17 freeze was not about the wedge |
| `xhci` (module swap) | the swap verified (`srcversion 0B4B25…`, `a16_*` parameters present), and the **next resume left a black screen** and no keyboard backlight → restart | don't swap it at runtime; land patches/0010 in the initramfs instead (`xhci persist`) |
| `ec install` (item 12) | EC bound, fans/temps/backlight all present — **radio still died in s2idle with it bound** | the EC is a working subsystem but not the radio's missing piece |

The tool now refuses `hook test`, `hook on` and the `xhci` swap unless `A16_I_KNOW=1`, and says why.

That leaves one lever that does not need a suspend to be safe: the driver.  `patches/0014` — keep the
device out of the SoC global reset on a resume, so MHI can re-attach to the firmware the suspend
deliberately kept (`ath12k_mhi_stop(is_suspend=true)` → `mhi_power_down_keep_dev()`); built natively
and ABI-verified (345 imports, all CRCs matched, `module_layout` `0xe6658f7b`):

    sudo ~/a16step        # one line, over ssh: install -> (start again) -> test -> verdict
    sudo ~/a16step status | verdict | log      # read-only;  xhci lands patches/0010 in the initramfs

If a resume leaves the screen black: the machine is usually alive — SSH in and read
`sudo journalctl -k -b | grep -E 'A16: resume|restart complete|MHI state'` instead of power-cycling,
because a hard reset is what loses the log.

## 7. The trap that cost the radio: a rebuilt module's EXPORTED CRCs (2026-09-22, after the restart)

patches/0014 was installed, the machine restarted, and **the Wi-Fi device had no driver at all**:

    ath12k_wifi7: disagrees about version of symbol ath12k_mac_op_get_survey
    ath12k_wifi7: Unknown symbol ath12k_mac_op_get_survey (err -22)
    ... (129 symbols, all of them ath12k's own)

`ath12k.ko` is loaded (our build: the `a16_skip_global_reset_on_resume` parameter is present), but
`ath12k_wifi7.ko` — the driver that actually binds the PCI device, and one we did **not** rebuild —
refuses it.  Cause, measured:

* this kernel was built with **gcc 15.2.0** (`/proc/version`: `aarch64-linux-gnu-gcc (Ubuntu
  15.2.0-16ubuntu1)`), the machine has **15.3.0**;
* the config has `CONFIG_EXTENDED_MODVERSIONS=y`, so a symbol's CRC is derived from the compiled
  DWARF; a different minor gcc yields different values;
* so 114 of the 134 CRCs in our `ath12k.ko`'s `__kcrctab` differed from the original build's, and the
  loader compares exactly that table when another module imports one of those symbols.

Everything else was fine — the module's *imports* all carried the kernel's CRCs (that is what the
existing ABI check verifies, and it passed 345/345) — which is why this went unnoticed: **imports and
exports are two different checks, and only the export side depends on our toolchain.**

The repair is exact rather than approximate: the exported symbol list and its order are identical to
the original build (`__ksymtab_strings` is byte-for-byte the same), so the original `__kcrctab` can be
transplanted whole and then verified byte-for-byte:

    objcopy --dump-section __kcrctab=/tmp/stock.crc /lib/modules/$KVER/kernel/.../ath12k.ko
    objcopy --update-section __kcrctab=/tmp/stock.crc <our ath12k.ko>

`a16-install-ath12k-resume-fix.sh` now does this after every build (`export_crc_check`), refuses to
stage or install a module whose export CRCs differ, and `a16step` checks that `ath12k_wifi7` actually
loaded before it starts a suspend test, with this message when it has not.

**The general rule, for every module this project rebuilds locally:** a module that exports symbols
*other* modules import must have its `__kcrctab` taken from the kernel's own copy of that module, or
the other module will refuse to load.  Modules that export nothing (gpucc-glymur, phy-qcom-edp,
msm, asus-glymur-ec, xhci-plat-hcd) are unaffected — which is why this is the first time it bit.

## 8. Two suspends with a16_keep_mhi_up=Y: one kept the radio, one did not (2026-09-22 11:52 / 12:29)

Both suspends are s2idle, both went through the new path, and the two outcomes differ:

**11:52 (boot -2) — kept the radio.** `WL4p1s0` still associated afterwards (the SSH session was over
it), no WMI timeouts:

    PM: suspend entry (s2idle)
    ath12k: A16: suspend -- keeping the MHI link and the device's firmware up
    ath12k: A16: resume -- the device and the MHI link were left up; re-arming the interrupts
    qcom_mhi_qrtr mhi0_IPCR: PM: failed to resume early: error -5
    PM: suspend exit

**12:29 (boot -1) — radio dead.** Same lines, same -5 on the QRTR MHI device, and then the WMI
transport never answers again:

    ath12k: A16: resume -- the device and the MHI link were left up; re-arming the interrupts
    qcom_mhi_qrtr mhi0_IPCR: failed to prepare for autoqueue transfer -5
    PM: suspend exit
    ath12k: wmi command 16387 timeout      (every ~13 s from then on)

So "leave the MHI link up" is necessary but not sufficient, and the second result looks exactly like
the device having lost power across the suspend after all: when the platform does take the WLAN's
power, the host's kept rings/HTC are useless and there is nothing left to talk to.  What decides that is
not known yet -- that is the open question, not the driver-side re-attach any more.

Two hazards found while following this up, both now disabled in the tools:

* **Unbinding the driver hangs, and the hang is worse than the dead radio.**
  `ath12k_pci_remove -> ath12k_pci_power_down -> ath12k_mhi_stop -> mhi_power_down -> __flush_work`
  never returns when the MHI is wedged in this state ("mhi mhi0: Device failed to clear MHI Reset"),
  so the shell that wrote to `unbind` sits in D state forever.  A task in D state cannot be frozen, so
  **every later system suspend fails**:

      Freezing user space processes failed after 20.004 seconds (1 tasks refusing to freeze, wq_busy=0):
      task:bash  state:D  pid:17679
        wait_for_completion -> __flush_work -> __mhi_power_down -> ath12k_mhi_stop
          -> ath12k_pci_power_down -> ath12k_core_deinit -> ath12k_pci_remove -> unbind_store

  That is what made the machine unusable (no radio, no dock, the lid doing nothing) on 12:33 while the
  kernel itself was alive.  `a16-wifi-recover.sh` rungs h2/h4 now refuse without `A16_IKNOW=1`, and
  `radiofix revive` refuses if this boot has had a failed resume *or* WMI timeouts.
* The way out of a wedged MHI is not a driver unbind but a **PCI function reset** (secondary bus
  reset / FLR), which clears the MHI state the driver's own teardown is waiting on.  That is the next
  recovery to build: reset the function first, then let the driver re-probe -- and never an unbind in
  the loop on a wedged device.

## 9. Why one resume kept the radio and the next did not: the PCIe link went down (2026-09-22)

The two suspends from §8 are identical in the driver log and differ in the PCIe log.  Side by side:

kept the radio (boot -2, 11:52)          lost the radio (boot -1, 12:29)

    A16: resume -- ... left up             A16: resume -- ... left up
    (no PCIe lines at all)                 pcieport 0004:00:00.0: Recovering Root Port due to Link Down
                                           ath12k_wifi7_pci 0004:01:00.0: AER: can't recover (no error_detected callback)
                                           qcom-pcie 1bf0000.pcie: PCIe Gen.3 x1 link up
                                           pcieport 0004:00:00.0: Root Port has been reset
                                           pcieport 0004:00:00.0: AER: device recovery failed
    qcom_mhi_qrtr mhi0_IPCR: ... -5        qcom_mhi_qrtr mhi0_IPCR: ... -5
    (radio associates again)               ath12k: wmi command 16387 timeout   (forever)

So the difference is not the driver and not the QRTR error (that appears in both): **the WLAN's PCIe
link was taken down across the suspend that lost the radio.**  The root port then re-initialised the
device behind the driver's back -- and the kernel says why nothing could be done about it:
`AER: can't recover (no error_detected callback)`, i.e. ath12k implements no PCIe error recovery, so a
link-down leaves the driver holding rings and a firmware that are gone (hence the WMI timeouts, and
hence why keeping the host side "up" in §8 helps only as long as the link never drops).

Two ways to go after it:

1. **Keep the link up** (this is the cheap test): `pcie_port_pm=off` stops the root port from being
   powered down across the suspend and `pcie_aspm=off` keeps the link out of L1, so the device is never
   re-initialised and the keep-MHI-up resume has something to resume.  Staged as
   `sudo bash ~/a16.sh pcielink arm` (params into entry [3]; `pcielink remove` undoes it), then one
   suspend test.  If the link stays up, that also explains the whole morning: the earlier resume
   failures (`MHI state 0x0`, `Wait for device to enter SBL`, `-22`) were the same event, since a
   device that was re-initialised behind the driver is neither running the old firmware nor in a state
   the driver's re-attach can use.
2. **Cope with the link going down** (the real fix, for upstream): implement PCIe error recovery in
   ath12k (`error_detected`/`slot_reset`/`resume`) so the AER path can re-probe the device instead of
   giving up.  That is what the kernel is asking for in the line above, and it is the only way a
   link-down can end with a working radio rather than a reboot.
