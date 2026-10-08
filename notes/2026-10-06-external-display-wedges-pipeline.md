# External displays can wedge the entire display pipeline (2026-10-06)

Both of today's "the screen won't come back" episodes have the same shape and two different kernel-side
mechanisms. Nothing was corrupted and no update caused it; the trigger is attaching an external output.

## Mode A — HDMI attached at boot: commits rejected, console never yields

- gnome-shell logs ~190 `Page flip failed: drmModeAtomicCommit: Invalid argument` per boot, starting at
  desktop start, and the boot ends with a power cut (no shutdown trace). Seen in 3 boots (13:55:06,
  13:56:18, 13:58:33).
- The kernel says nothing at all — the atomic check just returns EINVAL.
- The frame-buffer console stays bound the whole time (`/sys/class/vtconsole/vtcon1/bind = 1`) and is what
  is actually on the panel (plus fbcon's own cursor), i.e. the compositor never takes the display over.
- Recovery: unplug **and** a VT round trip (Ctrl+Alt+F3 then back) — the switch forces the handoff. Config
  changes through mutter's DisplayConfig API do **not** fix it (tried: monitor at 1920x1080, monitor
  dropped from the layout; both accepted, neither helped).
- Not yet explained by the kernel: needs one boot with `drm.debug=0x1ff` to see which part of the atomic
  state is refused. Tool staged for it: `BRINGUP/tools/a16-vt-test-entry.sh` (also drops `keep_bootcon`,
  the other suspect in the console-never-yields behaviour).

## Mode B — USB-C DP plugged in: link training fails, then the DPU wedges

Kernel log, all at 15:19:43–15:19:52:

    ucsi_glink ... con2: Firmware bug: duplicate partner altmode SVID 0xff01 at offset 27/28/29, ignoring
    [drm:msm_dp_ctrl_link_train_1_2 [msm]] *ERROR* link training #2 on phy 1 failed. ret=-110
    [drm:msm_dp_ctrl_setup_main_link [msm]] *ERROR* link training of LTTPR(s) failed. ret=-110
    [drm:msm_dp_display_atomic_enable [msm]] *ERROR* Failed link training (rc=-104)
    [drm:msm_dp_aux_isr [msm]] *ERROR* Unexpected DP AUX IRQ 0x01000000 when not busy
    [drm:msm_dp_ctrl_link_train_1_2 [msm]] *ERROR* link training #2 on phy 0 failed. ret=-110

and then the DPU giving up on time:

    [drm:dpu_encoder_phys_vid_wait_for_commit_done:545] [dpu error]vblank timeout: a0821300
    [drm:dpu_kms_wait_for_commit_done:527] [dpu error]wait for commit done returned -110
    [drm:dpu_encoder_frame_done_timeout:2730] [dpu error]enc38 frame done timeout

Consequences: both outputs are `enabled` in DRM while neither presents; gnome-shell sits at ~85% CPU and
its D-Bus interface stops answering (`gdbus ... GetCurrentState` times out, exit 124 — which is also why
rescue attempts through it fail); the USB-C monitor beeps (link timing arrives, no frames). Unplugging the
cable does **not** recover it — the encoder/vblank state stays wedged. Reboot with cables out is the only
recovery.

The `link training #2 ... ret=-110` signature is the same one as the eDP panel failure in
`2026-09-17-hermes-display-v8-edp-phy.md` — i.e. the DP outputs are hitting the same v8 PHY
programming-sequence problem, not a new class. The UCSI "duplicate partner altmode SVID" firmware bug is
upstream of it and worth reporting separately.

## Rules until this is fixed

- Keep external displays unplugged (HDMI and USB-C DP both qualify). The panel is collateral damage.
- Recovery is a reboot with cables out; nothing in userspace clears the wedged state.
- The DPU should fail the modeset and leave the panel alone instead of blocking on vblanks forever — that
  is worth a bug report on its own.

## Diagnostics that actually paid off

    journalctl -k -b | grep -iE 'dp_|dpu|vblank|link train'      # kernel side, names the mechanism
    cat /sys/class/drm/card1-*/enabled                            # enabled != presenting
    journalctl --user -b | grep -c 'Page flip failed'             # mode A signature
    ps -o pcpu,stat -p $(pgrep -x gnome-shell)                    # ~85% and spinning = wedged compositor
    timeout 8 gdbus call ... GetCurrentState                      # exit 124 = compositor not answering
