# The second suspend of a boot aborts on `xhci-hcd.1.auto`

What the logs show, why it takes the whole system suspend with it, the three places the wrong state
can come from, and the workaround staged in `patches/0010`.

## The symptom, once more

Boot `3a63a313` (and every boot since): the first suspend of a boot sleeps; from the resume onwards,
every attempt aborts within a second and `systemd-logind` retries it every ~33 s while the lid is
shut, so the machine never sleeps (fans on, ~6-7 W, ~10 %/h):

    kernel: PM: suspend entry (deep)
    kernel: xhci-hcd xhci-hcd.1.auto: PM: dpm_run_callback(): platform_pm_suspend returns -22
    kernel: xhci-hcd xhci-hcd.1.auto: PM: failed to suspend async: error -22
    kernel: PM: Some devices failed to suspend, or early wake event detected
    kernel: PM: suspend exit

Only `xhci-hcd.1.auto` (`a400000.usb`, the instance whose SuperSpeed bus carries the internal USB mass
storage device `0bda:0329`) does this; `xhci-hcd.2.auto` suspends fine.

## Where -22 comes from

`xhci_plat_suspend_common()` calls `xhci_suspend()` (`drivers/usb/host/xhci.c`) after the USB core has
suspended the root hubs, and `xhci_suspend()` bails out immediately when the HCD is not left suspended:

    if (hcd->state != HC_STATE_SUSPENDED ||
        (xhci->shared_hcd && xhci->shared_hcd->state != HC_STATE_SUSPENDED))
            return -EINVAL;

-22 *is* that `-EINVAL`. The platform callback's failure fails the whole system suspend (the log's
`PM: Some devices failed to suspend`), which is why one wedged USB controller costs the machine its
sleep instead of only its USB.

Inside xhci.c the only writer of `hcd->state = HC_STATE_SUSPENDED` is the resume path that resets the
controller (`xhci_resume()`, "Resume roothubs unconditionally as PORTSC change bits are not immediately
visible after xHC reset"); in normal operation the USB core sets it in `hcd_bus_suspend()`
(`drivers/usb/core/hcd.c`), reached from the *root hub's* suspend:

    usb_suspend_both()            drivers/usb/core/driver.c    (early-returns if udev->state == SUSPENDED)
      -> usb_suspend_device()     -> usb_generic_driver_suspend()  drivers/usb/core/generic.c
           -> hcd_bus_suspend()   (root hubs have no upstream port: "global suspend")
                -> xhci_bus_suspend()   -> hcd->state = HC_STATE_SUSPENDED

## The three ways the state can be wrong, and how to tell them apart

1. **The root hub was already `USB_STATE_SUSPENDED`.** `usb_suspend_both()` returns early for a device
   in that state, so `hcd_bus_suspend()` never runs and `hcd->state` keeps whatever it had (typically
   `HC_STATE_RUNNING`). This is the only path inside the core that produces exactly this pair of
   values, and it fits the "first suspend works, all later ones fail" shape: the first resume leaves a
   root hub suspended and nothing ever resumes it again.
2. **The root hub's suspend was skipped as "offloaded".** `usb_suspend_both()` skips
   `usb_suspend_device()` when `usb_offload_check(udev)` is true, and that check walks *children*
   (`drivers/usb/core/offload.c`), so a parent returns true if any device below it has
   `offload_usage != 0`. The only user of that counter is the Qualcomm USB-audio offload
   (`sound/usb/qcom/qc_audio_offload.c`), which is not in play on this machine unless a USB audio
   device is present, so this is unlikely here — but `xhci_plat_suspend()` has its own
   `xhci_sideband_check()` guard for exactly this case, and the two can disagree.
3. **`hcd_bus_suspend()` ran and failed**, restoring `hcd->state` to its previous value; then
   `hcd_bus_resume()` returns early (`HCD_RH_RUNNING(hcd)`) and never puts the state back. No
   `dev_dbg`/`dev_warn` from the core is in the boot log, which argues against this, but the core's
   messages are `dev_dbg` and would not appear at the default log level either way.

The three want different fixes, so the staged module logs what actually happens instead of guessing.

## The workaround staged (patches/0010, `xhci-plat-hcd.ko`)

`xhci-plat-hcd.ko` is the only loadable module on this path (`CONFIG_USB_XHCI_HCD=y`,
`CONFIG_USB_XHCI_PLATFORM=m`), so the change lives there, mirroring the existing
`sideband_at_suspend` pattern:

* on suspend: if `xhci_suspend()` returns `-EINVAL` and `hcd->state != HC_STATE_SUSPENDED`, log the
  states and **leave the controller running** (return 0) instead of failing the system suspend;
* on resume: if that happened, skip the matching `xhci_resume()` (the controller never stopped);
* at every suspend/resume: log `hcd->state`, `hcd->flags`, both root hubs' `udev->state`,
  `device_may_wakeup()` and `xhci->quirks`.

Both halves are module parameters, so a boot can be compared with and without them:

    /sys/module/xhci_plat_hcd/parameters/a16_skip_unsuspended_hcd   (fix, default 1)
    /sys/module/xhci_plat_hcd/parameters/a16_state_log              (logging, default 1)

Install with `sudo bash ~/a16.sh suspendfix`; it checks the module carries the change, that the
vermagic is the kernel's, and that every symbol the stock module imports still matches (62 imports,
`module_layout` CRC `0xe6658f7b`), then drops it in `/lib/modules/<ver>/updates/a16/` and runs
`depmod`. `suspendfix revert` takes it out; `suspendfix status` says which one is loaded.

## What it does and does not fix

* It makes the *system suspend* succeed again (so a closed lid sleeps instead of draining), and the
  log answers question 1/2/3 above in one test.
* It does **not** suspend the controller: with the workaround the USB block keeps running while the
  system sleeps, which may cost some of the sleep's power saving, and the root cause (whatever leaves
  `hcd->state` wrong) is still there. The proper fix depends on what the log shows — if it is case 1,
  it is a USB-core/driver state bug and belongs in a rebuilt kernel, not in this module.
* It does not touch the Wi-Fi wedge: `ath12k` still fails its firmware restart on the resume of the
  first suspend (`failed to resume core: -110`), and nothing recovers that radio without a reboot
  (`docs/wifi.md`). Keeping the controller running does not change what `ath12k` does.
