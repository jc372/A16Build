# 2026-09-17 — The real root cause: our modules were built with a config that disagrees with the kernel

This supersedes the conclusion in §3 of `2026-09-17-display-solved-hbr3.md` ("gen8's GPU path is
broken"). It was not the GPU. Every module we compiled from the native tree had **wrong struct
offsets**, because the tree's config was missing `CONFIG_SCHED_CLASS_EXT`, which the running kernel
has.

## The chain, in order

1. `pahole` is not installed on the machine.
2. `CONFIG_DEBUG_INFO_BTF` depends on a usable pahole, so kconfig **silently dropped it** — along
   with everything that selects it.
3. `config SCHED_CLASS_EXT` (`kernel/Kconfig.preempt:170`) is
   `depends on BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF`, so sched_ext was dropped too.
4. `struct task_struct` therefore lost its embedded `struct sched_ext_entity scx`, and **every
   field after it moved**:

       field          kernel (BTF)    our broken build (DWARF)
       scx            840             absent
       group_leader   2104            1784
       thread_pid     2144            1824        <- 320 bytes out

5. Our `msm.ko` then read `task->thread_pid` at 1824, which holds something else entirely.

## Why it looked like three different GPU bugs

Every oops was "the first `get_pid()` in the module", in three different functions, because
`get_pid(task_pid(...))` is the first thing that dereferences a task field:

    msm_gpu_create_private_vm   to_msm_vm(vm)->pid = get_pid(task_pid(task));
    adreno_get_param            (same path, via msm_context_vm)
    submit_create               submit->pid = get_pid(task_pid(current));   msm_gem_submit.c:70

Everything else worked — the panel, the eDP link at HBR3, the clock controllers, the PHY — because
none of it touches `task_struct`. That asymmetry was the clue.

## Two traps that hid it

- **`srcversion` does not change when struct layouts change.** A rebuilt module can carry the same
  srcversion as the broken one it replaces. Phase detection in `a16-gpu-fix.sh` now compares
  **sha256** of the .ko files instead, and checks the ABI (below) before it will start a desktop.
- **`make M=drivers/gpu/drm/msm` never regenerates `include/generated/autoconf.h`.** Copying the
  kernel's `/boot/config-$(uname -r)` over `.config` proves nothing until a *top-level*
  `make syncconfig` runs; until then the compiler still sees the old config. A "clean" module
  rebuild will happily produce a module with the old layout.

## The fix, reproducible

`tools/a16-fix-build-config.sh` does all of it and **verifies** it:

    pahole                  (apt, or extracted locally with dpkg-deb; the script does either)
    cp /boot/config-$(uname -r) .config
    ./scripts/config --module CLK_GLYMUR_GPUCC CLK_KAANAPALI_GCC CLK_KAANAPALI_GPUCC
    make ARCH=arm64 olddefconfig      # keeps DEBUG_INFO_BTF=y, SCHED_CLASS_EXT=y, EXT_*_SCHED=y
    make ARCH=arm64 syncconfig        # writes include/generated/autoconf.h  <- the step that matters
    make ARCH=arm64 M=drivers/gpu/drm/msm clean && make ... msm.ko

Verification, which the script also performs (`gdb` on the module's DWARF vs `bpftool` on the
kernel's BTF):

    installed updates/a16/msm.ko    thread_pid kernel=2144 module=1824  MISMATCH
    freshly rebuilt msm.ko          thread_pid kernel=2144 module=2144  OK

`a16-gpu-fix.sh` runs that check as "test 0" and **refuses to start the desktop** while it says
MISMATCH.

## Also worth knowing

- The installed `phy-qcom-edp.ko` (the v8 PHY series build) has the same wrong offsets: 1824. It
  works because the PHY code never touches `task_struct`, but it should be rebuilt the same way
  before it is trusted for anything else.
- The stock kernel modules report "no debug info to check" (stripped), which is expected: only
  modules we build ourselves can be checked this way.
- `patches/0010` (dropping `.create_private_vm` from `a8xx_gpu_funcs`) was a workaround for a
  symptom of this bug. It is reverted; the GPU path is upstream code again, and the only change
  from stock that remains in msm is the HBR3 rate force in `patches/0009`.
