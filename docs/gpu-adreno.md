# GPU — adreno gen8 and its clock controller

**State: the device works; userspace support is missing.** `adreno 3d00000.gpu` binds, the GMU
firmware loads, `/dev/dri/renderD128` exists — but mesa's freedreno refuses this chip, so rendering
falls back to software. The kernel side is complete; the gap is in mesa.

## The hardware

| | |
|---|---|
| GPU | Qualcomm Adreno, gen8 (`a8xx`), at `3d00000.gpu` |
| GMU | `3d6c000.gmu`, firmware `qcom/gen80100_gmu.bin` + `qcom/gen80100_sqe.fw` |
| SMMU | `3da0000.iommu` |
| Clock controllers | `gpucc-glymur` at `3d90000.clock-controller`, `gxclkctl-kaanapali` at `3d64000.clock-controller` |
| Mesa chip id, as reported by userspace | `0x18444070041` |

## The bring-up chain, in the order it must succeed

    gpucc-glymur (3d90000)  ->  gxclkctl-kaanapali (3d64000)  ->  arm-smmu (3da0000)
      ->  adreno (3d00000, loads GMU firmware)  ->  msm_dpu (ae01000)  ->  DRM device

If any link is missing, everything downstream defers, and the visible symptom is *no DRM device*
(`/proc/fb` stays `simpledrmdrmfb`, no `/sys/class/backlight`, no refresh choices) — which is what
the machine looked like before this was sorted.

## Cause: a missing config symbol

    # CONFIG_CLK_GLYMUR_GPUCC is not set        (the machine's kernel config)

That one symbol is the Glymur GPU clock controller. Without it `gxclkctl-kaanapali` cannot get its
power domain, `arm-smmu` fails `-110`, adreno never binds, and `msm` never binds:

    adreno 3d00000.gpu: deferred probe timeout
    arm-smmu 3da0000.iommu: probe failed -110
    gxclkctl-kaanapali 3d64000.clock-controller: failed -110
    msm_dpu ae01000.display-controller: failed to bind 3d00000.gpu (ops a3xx_ops): -19

The fix is a **build-config change, not a patch**: build `gpucc-glymur.ko` (and
`gxclkctl-kaanapali.ko`, which `CONFIG_CLK_KAANAPALI_GPUCC=m` builds) from the matching tree and
install them into `updates/`. See [build.md](build.md) for the config/CRC discipline.

**The change this needs:** `CONFIG_CLK_GLYMUR_GPUCC` (and `CONFIG_CLK_KAANAPALI_GPUCC`) set to
`y`/`m` in a Glymur/`ARCH_QCOM` arm64 build. Nothing else in this repository is needed for the GPU
to bind.

## Once it is bound

    journalctl -k -b 0 -o cat | grep -E 'adreno|GMU'
      [drm:adreno_request_fw] loaded qcom/gen80100_sqe.fw from new location
      [drm:adreno_request_fw] loaded qcom/gen80100_gmu.bin from new location
      [drm] Loaded GMU firmware v5.2.38
      Zap shader not enabled - using SECVID_TRUST_CNTL instead

The "Zap shader" line is expected on this machine (the secure zap path is used instead).

    ls /dev/dri/                          # card1  renderD128
    ls /sys/bus/platform/drivers/adreno/  # 3d00000.gpu

## The remaining gap is in mesa, not the kernel

Any application that tries to use the GPU gets:

    MESA: error: fd_pipe_new2:49: unsupported GPU id 0x0 / chip id 0x18444070041
    libEGL warning: egl: failed to create dri2 screen

so it falls back to llvmpipe. gnome-shell itself still comes up (Wayland session, EGL context
obtained). This is a freedreno support question for gen8 — worth reporting to mesa with the chip id
above; there is nothing for us to patch in the kernel.

## A failure that looked like a GPU driver bug

Our own `msm.ko` used to oops here, in the GPU private-VM path, and it looked exactly like a gen8
driver bug:

    msm_gpu_create_private_vm  <-  msm_context_vm  <-  adreno_get_param    (any MSM_GET_PARAM)

It was not. It was the build-config mismatch in [build.md](build.md) (missing pahole →
`SCHED_CLASS_EXT` off → wrong `task_struct` offsets), and the only reason it showed up in GPU code
is that GPU paths are the first to call `get_pid(task_pid(...))`. The workaround written for it
(`patches/0010`, dropping `.create_private_vm` for a8xx) is retired. The ABI verification in
`scripts/a16-fix-build-config.sh` detects this condition.

## Verify

    cat /sys/module/msm/srcversion                        # our build's srcversion
    sha256sum /lib/modules/$(uname -r)/updates/a16/msm.ko # compare against the tree's build
    ls /dev/dri/renderD128
    journalctl -k -b 0 -o cat | grep -c deferred           # should be none for gpu/gpucc/gmu
