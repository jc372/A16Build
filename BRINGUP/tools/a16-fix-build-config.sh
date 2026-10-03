#!/usr/bin/env bash
# a16-fix-build-config.sh -- make the native build tree's config (and generated headers) match the
# running kernel, and PROVE it, before building any module.
#
# Why this exists: a module built from this tree was oopsing the kernel three times in a row, in
# completely unrelated places, all of them "the first get_pid() in the module":
#
#     msm_gpu_create_private_vm:  to_msm_vm(vm)->pid = get_pid(task_pid(task));
#     submit_create:              submit->pid = get_pid(task_pid(current));
#
# The cause was not the GPU.  Our tree's .config was missing CONFIG_SCHED_CLASS_EXT, which the
# running kernel has.  That option embeds `struct sched_ext_entity scx` inside struct task_struct,
# so every field after it sits at a different offset:
#
#     thread_pid   kernel 2144      our broken build 1824     (320 bytes out)
#
# ...so `task->thread_pid` read whatever happened to be at 1824.  Chain: pahole is not installed ->
# kconfig drops CONFIG_DEBUG_INFO_BTF (sched_ext depends on it) -> drops CONFIG_SCHED_CLASS_EXT.
# And `make M=...` never regenerates include/generated/autoconf.h, so even copying the kernel's
# /boot/config over proves nothing until `make syncconfig` runs at the top level.
#
# Usage:  bash a16-fix-build-config.sh            # fix + verify offsets
#         bash a16-fix-build-config.sh --check    # only report
set -u
T=${A16_TREE:-/home/jc/build/linux-next-1a1de54f7369}
KV=$(uname -r)
PAHOLE_LOCAL=/home/jc/pahole-local
say(){ printf '%s\n' "$*"; }

export PATH="$PAHOLE_LOCAL/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PAHOLE_LOCAL/usr/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# --- the kernel's own answers, straight out of its BTF -------------------------------------------
kernel_off() {
  bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>/dev/null | python3 -c "
import sys,re
want='$1'
lines=sys.stdin.read().split('\n')
for i,l in enumerate(lines):
    if re.match(r\"\[\d+\] STRUCT 'task_struct' \", l) and 'size=' in l:
        for m in lines[i+1:]:
            if not m.startswith('\t'): break
            g=re.match(r\"\t'(\w+)' type_id=\d+ bits_offset=(\d+)\", m)
            if g and g.group(1)==want: print(int(g.group(2))//8); sys.exit()
"
}
K_THREAD_PID=$(kernel_off thread_pid); K_GROUP_LEADER=$(kernel_off group_leader)
say "kernel (from its BTF) : thread_pid=$K_THREAD_PID  group_leader=$K_GROUP_LEADER"

if [ "${1:-}" = "--check" ]; then
  say "tree .config          : SCHED_CLASS_EXT=$(grep -c '^CONFIG_SCHED_CLASS_EXT=y' $T/.config 2>/dev/null) DEBUG_INFO_BTF=$(grep -c '^CONFIG_DEBUG_INFO_BTF=y' $T/.config 2>/dev/null)"
  say "generated autoconf.h  : SCHED_CLASS_EXT=$(grep -c 'CONFIG_SCHED_CLASS_EXT' $T/include/generated/autoconf.h 2>/dev/null)"
  say "pahole                : $(PATH=$PAHOLE_LOCAL/usr/bin:$PATH pahole --version 2>/dev/null || echo 'not found')"
  say "kernel config file    : /boot/config-$KV  (SCHED_CLASS_EXT: $(grep -c '^CONFIG_SCHED_CLASS_EXT=y' /boot/config-$KV))"
  exit 0
fi

cd "$T" || { say "FATAL: no tree at $T"; exit 1; }

say "1. pahole -- without it kconfig drops BTF and sched_ext"
if ! pahole --version >/dev/null 2>&1; then
  say "   not found; extracting the .deb locally (no root needed)"
  mkdir -p /tmp/.a16pahole && cd /tmp/.a16pahole || exit 1
  for p in pahole libdwarves1 libbpf1 libelf1t64; do apt-get download "$p" >/dev/null 2>&1 || true; done
  for d in *.deb; do dpkg-deb -x "$d" "$PAHOLE_LOCAL" >/dev/null 2>&1 || true; done
  cd "$T" || exit 1
  say "   $(pahole --version 2>/dev/null || echo 'still missing -- install pahole with apt')"
else
  say "   $(pahole --version)"
fi

say "2. take the running kernel's config and keep our Glymur clock options"
cp -a /boot/config-$KV .config
for s in CLK_GLYMUR_GPUCC CLK_KAANAPALI_GCC CLK_KAANAPALI_GPUCC; do ./scripts/config --module "$s"; done

say "3. resolve it -- this is the step that was silently dropping options"
make --no-print-directory ARCH=arm64 olddefconfig 2>&1 | tail -1 | sed 's/^/   /'
for o in DEBUG_INFO_BTF SCHED_CLASS_EXT EXT_GROUP_SCHED EXT_SUB_SCHED; do
  printf '   %-20s %s\n' "$o" "$(grep -E "^CONFIG_$o=" .config || echo '*** STILL DROPPED ***')"
done

say "4. regenerate include/generated (make M=... never does this)"
make --no-print-directory ARCH=arm64 syncconfig 2>&1 | tail -1 | sed 's/^/   /'
say "   autoconf.h: SCHED_CLASS_EXT=$(grep -c 'CONFIG_SCHED_CLASS_EXT' include/generated/autoconf.h)"

say "5. PROOF: compile a throwaway object and compare struct offsets with the kernel's BTF"
probe=/tmp/.a16_off.c
printf '#include <linux/sched.h>\n#include <linux/pid.h>\nvoid a16_off(void){ BUILD_BUG_ON(offsetof(struct task_struct, thread_pid) != %s); }\n' "$K_THREAD_PID" > "$probe"
if make --no-print-directory ARCH=arm64 M=drivers/gpu/drm/msm msm.o >/dev/null 2>&1; then
  got=$(gdb -batch -ex 'ptype /o struct task_struct' drivers/gpu/drm/msm/msm.o 2>/dev/null | awk '/thread_pid;/{print $2; exit}')
  say "   our freshly compiled msm.o says thread_pid = $got   (kernel: $K_THREAD_PID)"
  if [ "$got" = "$K_THREAD_PID" ]; then
    say "   ✓ the module ABI now matches the kernel"
  else
    say "   ✗ STILL WRONG -- do not install anything built from this tree"
    exit 1
  fi
else
  say "   (could not compile a probe object -- build msm.o by hand and check with gdb)"
fi

say ""
say "Now rebuild what you need, e.g.:"
say "   make --no-print-directory ARCH=arm64 M=drivers/gpu/drm/msm clean && \\"
say "   make --no-print-directory -j4 ARCH=arm64 M=drivers/gpu/drm/msm msm.ko"
say "and only then install it."
