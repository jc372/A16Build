# 2026-09-17 — the panel works: the eDP link trains at HBR3, and what still blocks the desktop

Entry [3], kernel `7.3.0-rc3-next-20260914`, tree commit `1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`.
This closes the display question from item 7 for the *link*, and names the new blocker.

## 1. What was wrong: the rate msm chose, not the PHY

The v8 eDP PHY sequence is broken for rates other than 4-lane 8.1 G. Upstream's own words, in
Bjorn Andersson's posted-but-unmerged series (`phy: qcom: edp: Update v8 programming sequence`,
2026-06-22, patchwork `changes-requested`):

> The programming sequences introduced for v8 doesn't work other than for 4-lane 8.1Gbps. For
> 2-lane 5.4Gbps link training fails and for 2.7 and 1.62Gbps PLL lock isn't reached.

Our panel's SUPPORTED_LINK_RATES list stops at 540000 (HBR2), so msm picked the one rate family
the sequence gets wrong. The failure signature was always identical:

    link_rate=540000  num_lanes=4  using LINK_BW_SET: 0x14
    link training #1 on phy 0 successful        (clock recovery fine)
    link training #2 on phy 0 failed. ret=-110  (channel equalization never converges)
    DPCD 0x202: 11 11 -> 11 11 (no EQ, no symbol lock), adjust request 0x22 then 0x44

Ruled out on the way, each experimentally:

- the v8 *drive table* (patches/0004) — identical failure
- the emphasis enable mask `TXn_TRAN_DRVR_EMP_EN` 0x01 -> 0x5f (patches/0005) — identical failure
- the posted v8 PHY series itself, installed as the live `phy-qcom-edp.ko` — identical failure
  (the series covers 2-lane 5.4 and 4-lane 8.1, not our 4-lane 5.4)
- the sink rejecting TPS3, or the scrambler being left on — both correct as coded
- lane wiring — `data-lanes = <0 1 2 3>` on the `af6c000` endpoint
- anything in upstream newer than our tree: `dp_ctrl.c`, `dp_link.c`, `dp_panel.c`,
  `panel-samsung-atna33xc20.c` are identical to today's linux-next

## 2. What fixed it: take the highest rate the DT allows

`patches/0009-drm-msm-dp-force-edp-rate-to-hbr3-experiment.patch` — in
`msm_dp_panel_read_link_caps()`, after the loop that walks the sink's advertised rate list:

    if (link->max_dp_link_rate >= 810000) {
            link_info->rate = 810000;
            link_info->rate_set = 3;   /* 0x1E in the eDP supported-link-rates table */
    }

Independent evidence for the choice: another A16 owner's rate sweep on this same panel model —
*"RBR/HBR fail clock recovery, HBR2 passes CR and fails EQ, HBR3 trains and the panel lights"* —
and upstream's own v8 validation, which covers 4-lane 8.1 G. Our DT's `link-frequencies` already
reach 8.1 G, so nothing in the device tree needed to change.

First boot with it, entry [3]:

    link_rate=810000
    rate=810000, num_lanes=4, pixel_rate=709633
    using LINK_BW_SET: 0x1e
    link training #1 on phy 0 successful
    link training #2 on phy 0 successful      <-- first time ever
    msm_dp_ctrl_prepare_stream_on: rate=810000, num_lanes=4

and with it, everything item 7 asked for:

    card1-eDP-1   status=connected  enabled=enabled  modes=2880x1800 (120 Hz preferred, 60 Hz)
    /proc/fb      msmdrmfb
    backlight     /sys/class/backlight/dp_aux_backlight  (brightness/max 628/2047 at the time)

So both of the original user-visible symptoms (no brightness, no refresh choice) are unblocked:
the backlight class device exists and the connector advertises 120 Hz. Both are reachable at a
text console, which is where to verify them — see the boot-snapshot/serial workflow in the README.

Staging is one command: `sudo bash tools/a16-stage-phy-v8fix-test.sh` installs the PHY module and
the rebuilt `msm.ko` (and re-arms entry [3]'s parameters). The HBR3 module is *required*; the PHY
series is optional for us at 8.1 G but harmless and it is upstream's intended fix, so it stays.

## 3. The new blocker: GNOME oopsed in msm's GPU private-VM path  [CORRECTED 2026-09-17]

The text console and the panel are fine. Starting the desktop is what kills it:

    Internal error: Oops: 0000000096000004 [#1]  SMP
    FSC = 0x04: level 0 translation fault          (a data access to an unmapped *user* address)
    CPU: 3 PID: 4557 Comm: gnome-shell
    pc : msm_gpu_create_private_vm+0x6c/0x1c0 [msm]
    Call trace:
      msm_gpu_create_private_vm+0x6c/0x1c0 [msm]
      msm_context_vm+0xcc/0x128 [msm]
      adreno_get_param+0x40/0x440 [msm]
      msm_ioctl_get_param+0x58/0xe0 [msm]
      drm_ioctl_kernel / drm_ioctl / __arm64_sys_ioctl

**CORRECTION (same day):** this was *not* a gen8 GPU bug.  Every module built from our tree
had wrong `struct task_struct` offsets because the tree's config was missing
`CONFIG_SCHED_CLASS_EXT` (pahole absent -> BTF dropped -> sched_ext dropped).  See
`2026-09-17-build-config-mismatch.md`.  `patches/0010` was a symptom workaround and is
reverted; the earlier traces below are kept as evidence of the symptom, not the cause. After the oops the box wedges
(soft lockups on CPU#1 in `__smp_call_function_single`, RCU stalls) and needs a power cycle —
which is what "the GUI went black and I had to hard reset" was.

Why the console survives and the desktop does not: fbcon drives the display without ever touching
the GPU. `MSM_GET_PARAM` does, and `adreno_get_param()` creates the context's private VM *eagerly*
on any param query:

    adreno_gpu.c:371   struct drm_gpuvm *vm = ctx ? msm_context_vm(drm, ctx) : NULL;
    msm_drv.c:236      vm = msm_gpu_create_private_vm(priv->gpu, current, !ctx->userspace_managed_vm);
    msm_gpu.c:877      vm = gpu->funcs->create_private_vm(gpu, kernel_managed);
    msm_gpu.c:879      to_msm_vm(vm)->pid = get_pid(task_pid(task));

So every GPU client pays for it, not just VM_BIND users. The only implementation is
`a6xx_create_private_vm()` (`adreno/a6xx_gpu.c:2379`), whose first act is

    mmu = msm_iommu_pagetable_create(to_msm_vm(gpu->vm)->mmu, kernel_managed);

and it is wired into the gen8 funcs too (`a8xx_gpu_funcs`, `a6xx_gpu.c:2904`), i.e. our Glymur
GPU gets a6xx's per-process-pagetable path. Two things to check next, in this order:

1. whether `gpu->vm` on a8xx is really an `msm_vm` (the `to_msm_vm()` cast is where a bogus
   pointer would come from), and what `msm_gem_vm_create()`/`adreno_private_vm_size()` do on gen8;
2. whether upstream changed any of this after our tree's date (2026-09-14) — if the fix is already
   posted, take it; if not, the local workaround is to drop `.create_private_vm` from
   `a8xx_gpu_funcs` so the context falls back to the global VM instead of entering the broken path.

## 4. The workaround that turned out to be unnecessary: CPU rendering

`tools/a16-enable-software-gl.sh` puts the software GL stack in `/etc/environment`
(`LIBGL_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`, `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast`)
so the session stops selecting the msm GL driver and therefore never issues the param that oopses.
There is no X server installed, so this is the Wayland + software-GL path, not X11 + llvmpipe.
Revert with `--revert`.
