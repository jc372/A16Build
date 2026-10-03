# Phase 6 — after any kernel change: rebuilding the modules

Everything the machine needs that is not in the stock kernel is a module built separately, from
the linux-next tree the running kernel came from. They must match that kernel exactly, and the check that
proves it is not optional.

## 6.1 The requirement

A module built from a tree whose configuration disagrees with the running kernel has **wrong struct
offsets**. It loads without complaint — vermagic and symbol CRCs still match — and then oopses in
whichever function first touches a field that moved. On this machine that produced three kernel oopses
in three unrelated functions, and it was misdiagnosed as a GPU driver bug.

The chain, in full:

    pahole missing
      -> kconfig drops CONFIG_DEBUG_INFO_BTF
      -> CONFIG_SCHED_CLASS_EXT is dropped (it depends on DEBUG_INFO_BTF)
      -> struct task_struct loses its embedded struct sched_ext_entity scx
      -> every later field shifts: thread_pid is at 2144 in the kernel, 1824 in the mismatched build

Two details make it hard to notice:

- `srcversion` does **not** change when struct layouts change, so it cannot tell you whether a module
  is current. Compare `sha256sum` of the `.ko` files.
- `make M=...` never regenerates `include/generated/autoconf.h`. Copying the kernel's config over
  `.config` proves nothing until a top-level `make syncconfig` runs; a "clean" module rebuild happily
  produces a module with the old layout.

## 6.2 The check, and the scripts that do it

    sudo bash scripts/a16-bootstrap.sh --check     # tools, tree, patches, config, modules, options
    sudo bash scripts/a16-bootstrap.sh --all       # do all of it
    # or, just the config and the verification:
    sudo bash scripts/a16-fix-build-config.sh

The verification compares a field offset compiled into the module (from its DWARF) with the running
kernel's own value (from its BTF):

    bpftool btf dump file /sys/kernel/btf/vmlinux format raw   # kernel:  thread_pid 2144
    gdb -batch -ex 'ptype /o struct task_struct' msm.ko        # module:  must also be 2144

`scripts/a16-install-gpucc-module.sh` refuses to install a module whose vermagic or `module_layout`
CRC does not match, and `scripts/a16-gpu-fix.sh` stops before starting the desktop if the ABI check
fails. Full detail: `docs/build.md`.

## 6.3 The normal rebuild

    sudo bash scripts/a16-bootstrap.sh --config     # keep the config matching the kernel
    sudo bash scripts/a16-bootstrap.sh --build      # gpucc-glymur, gxclkctl-kaanapali, phy-qcom-edp, msm
    sudo bash scripts/a16-bootstrap.sh --install    # into /lib/modules/$(uname -r)/updates + depmod
    sudo reboot

Modules installed under `updates/` take precedence over the kernel's own, for `modprobe` and for
kernel autoload by device-tree compatible, which is how the panel's PHY is matched. Removing them
(`rm` + `depmod -a`) returns the machine to the stock modules.
