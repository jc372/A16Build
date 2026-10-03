# Building modules for this machine

Everything here is built **on the A16 itself** — it has the toolchain installed and a Wi-Fi
connection; there is no cross-build host in the loop any more.

## Tools

    build-essential  flex  bison  bc  git  rsync  kmod  cpio  python3
    libdw-dev        CONFIG_EXTENDED_MODVERSIONS=y makes gendwarfksyms need libdw.h
    libelf-dev
    pahole (dwarves) *** required, see below ***

`scripts/a16-bootstrap.sh --tools` installs all of them. On this machine `pahole` also works
extracted locally (no root) with `dpkg-deb -x` into `~/pahole-local` plus
`LD_LIBRARY_PATH=~/pahole-local/usr/lib/aarch64-linux-gnu`.

## The tree

    commit 1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3        (linux-next, matches the running kernel)
    https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/1a1de54f....tar.gz

The snapshot tarball (~271 MB, 96 347 files, 1.8 GB extracted) is the practical way in: the
`/plain/` endpoint of git.kernel.org is behind an anti-bot wall, and a full clone of linux-next is
unnecessary for a module-only build.

## A config that disagrees with the running kernel makes every struct offset wrong

This cost an evening and produced three kernel oopses in three unrelated functions. It will happen
again to anyone who builds here without reading this.

- `pahole` missing → kconfig drops `CONFIG_DEBUG_INFO_BTF` → `SCHED_CLASS_EXT`
  (`kernel/Kconfig.preempt`, `depends on BPF_SYSCALL && BPF_JIT && DEBUG_INFO_BTF`) is dropped too →
  `struct task_struct` loses its embedded `scx` → **every field after it moves**:

      field          running kernel    build without pahole
      scx            840               absent
      group_leader   2104              1784
      thread_pid     2144              1824

- The symptom is not "it fails to load" (vermagic and symbol CRCs still match!). It is *oopses in
  whichever function first dereferences a task field* — for us `get_pid(task_pid(...))` in three
  different places. The check below detects this condition.
- `srcversion` does **not** change when struct layouts change, so it is useless for deciding whether
  a module is current. Compare `sha256sum`.

## The build recipe

Use the scripted version, `scripts/a16-fix-build-config.sh` (or the same steps via
`scripts/a16-bootstrap.sh --config`):

    cp /boot/config-$(uname -r) .config
    ./scripts/config --module CLK_GLYMUR_GPUCC CLK_KAANAPALI_GCC CLK_KAANAPALI_GPUCC
    make ARCH=arm64 olddefconfig     # must keep: DEBUG_INFO_BTF=y, SCHED_CLASS_EXT=y, EXT_*_SCHED=y
    make ARCH=arm64 syncconfig       # <-- writes include/generated/autoconf.h.  make M=... never does.
    make ARCH=arm64 M=drivers/gpu/drm/msm clean
    make ARCH=arm64 M=drivers/gpu/drm/msm msm.ko

Then **verify before installing**, which the script also does — it compares a field offset compiled
into the module's DWARF against the running kernel's BTF:

    bpftool btf dump file /sys/kernel/btf/vmlinux format raw | grep -A400 "STRUCT 'task_struct'"   # kernel
    gdb -batch -ex 'ptype /o struct task_struct' msm.ko | grep thread_pid                            # module

Expected: `thread_pid 2144` on both sides. Any other value means the tree's config does not
match the kernel's. (Stock kernel
modules report "no debug info"; only modules we build can be checked this way.)

## Symbol CRCs for module-only builds

`CONFIG_MODVERSIONS=y` means a module's imported symbols are CRC-checked at load. For a module-only
build we harvest the running kernel's `__versions` from the installed modules (25 530 CRCs at the
time of writing) into `Module.symvers`, so vermagic and every CRC match.
`BRINGUP/tools/a16-build-gpucc-native.sh` does this and is the reference implementation.

## Installing, and why `updates/` matters

Modules we build go to `/lib/modules/$(uname -r)/updates/...`. `depmod` puts `updates/` ahead of
`kernel/`, so our module wins for both `modprobe` and kernel autoload — including by OF alias, which
is how the panel's PHY is matched. Always `depmod -a "$(uname -r)"` afterwards, and check what will
actually be loaded:

    modinfo -F filename msm                     # must be .../updates/a16/msm.ko
    modinfo -F filename phy-qcom-edp            # must be .../updates/a16/phy-qcom-edp.ko

The installer used throughout, `BRINGUP/tools/a16-install-gpucc-module.sh`, **refuses** to install a
module whose vermagic or `module_layout` CRC does not match the running kernel. Copying modules
into place by hand bypasses that check.

## Removing our modules

    rm -f /lib/modules/$(uname -r)/updates/a16/{msm.ko,phy-qcom-edp.ko}
    depmod -a "$(uname -r)"

That restores the stock modules and, with the firmware-framebuffer boot option, a working (if
feature-poor) machine.
