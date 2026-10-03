#!/usr/bin/env bash
# a16-abi-layout-gate.sh <kernel-tree> [more-trees...]
#
# WHY THIS EXISTS
#   modversions (symbol CRCs) only cover exported function prototypes. Inlined
#   structure accessors (task_pid() -> task_struct.thread_pid) are invisible to
#   them, so a build tree whose .config / include/generated/autoconf.h does not
#   match the running kernel produces modules that LOAD FINE and then read the
#   wrong memory. That is what produced the page fault in
#   msm_gpu_create_private_vm on 2026-10-02: the module read task->thread_pid at
#   byte offset 1824 while the running kernel has it at 2144.
#
# WHAT IT DOES
#   Reads the running kernel's real struct offsets out of /sys/kernel/btf/vmlinux
#   and compiles a throwaway module against the given tree that _Static_assert()s
#   every one of them. If the tree's headers disagree with the running kernel the
#   compile fails and names the field.
#
# RUN THIS BEFORE EVERY MODULE BUILD THAT WILL BE STAGED ON THE MACHINE.
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <kernel-tree> [more-trees...]"; exit 2; }

kver=$(uname -r)
btf=/sys/kernel/btf/vmlinux
[ -r "$btf" ] || { echo "FATAL: $btf not readable (CONFIG_DEBUG_INFO_BTF?)"; exit 1; }

# pahole: prefer one on PATH, fall back to the local build used on this machine
PAHOLE=$(command -v pahole || true)
if [ -z "$PAHOLE" ]; then
    for cand in "$HOME/.hermes/cache/scratch/pahole-local/usr/bin/pahole" "$HOME/bin/pahole"; do
        [ -x "$cand" ] && PAHOLE="$cand" && break
    done
fi
[ -n "$PAHOLE" ] || { echo "FATAL: pahole not found (needed to read $btf)"; exit 1; }
export PATH="$(dirname "$PAHOLE"):$PATH"
libdir=$(dirname "$(dirname "$PAHOLE")")/lib/aarch64-linux-gnu
[ -d "$libdir" ] && export LD_LIBRARY_PATH="$libdir:${LD_LIBRARY_PATH:-}"

# Structures whose layout actually matters to the modules built here.
# Add a line when a new module starts touching a new kernel structure.
# override with A16_ABI_FIELDS="struct:member struct:member ..." to probe more
FIELDS="${A16_ABI_FIELDS:-task_struct:thread_pid task_struct:pid task_struct:comm task_struct:cred task_struct:mm task_struct:sched_class task_struct:flags}"

work=$(mktemp -d "${TMPDIR:-/tmp}/abi-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

"$PAHOLE" -C task_struct "$btf" > "$work/task_struct.txt" 2>/dev/null || true

python3 - "$work/task_struct.txt" "$work/abigate.c" $FIELDS <<'PY'
import re, sys
src, out = sys.argv[1], sys.argv[2]
fields = [a.split(':', 1) for a in sys.argv[3:]]
text = open(src).read()
# map member -> byte offset, using the LAST identifier before ';' as the member
# name ("const struct cred __rcu *ptracer_cred;" must NOT answer for "cred")
members = {}
for line in text.splitlines():
    m = re.match(r'^\s*(.+?);\s*/\*\s*(\d+)(?:\s+(\d+))?\s*\*/\s*$', line)
    if not m:
        continue
    ids = re.findall(r'[A-Za-z_]\w*', m.group(1))
    if ids:
        members[ids[-1]] = int(m.group(2))
body, missing = [], []
for st, mem in fields:
    if mem not in members:
        missing.append('%s.%s' % (st, mem))
        continue
    off = members[mem]
    body.append('_Static_assert(offsetof(struct %s, %s) == %s, '
                '"%s.%s offset differs from the running kernel");'
                % (st, mem, off, st, mem))
    print('  %s.%-22s kernel offset %s' % (st, mem, off))
for x in missing:
    print('  note: %s not present in BTF, skipped' % x)
with open(out, 'w') as f:
    f.write('#include <linux/module.h>\n#include <linux/sched.h>\n'
            '#include <linux/sched/mm.h>\n#include <linux/cred.h>\n'
            '#include <linux/pid.h>\n\n' + '\n'.join(body) + '\n\n'
            'static int __init abigate_init(void) { return 0; }\n'
            'static void __exit abigate_exit(void) { }\n'
            'module_init(abigate_init);\nmodule_exit(abigate_exit);\n'
            'MODULE_LICENSE("GPL");\n')
if not body:
    print('FATAL: no fields resolved from BTF')
    sys.exit(3)
PY

printf 'obj-m := abigate.o\n' > "$work/Makefile"

rc=0
for tree in "$@"; do
    [ -d "$tree" ] || { echo "FAIL $tree (no such tree)"; rc=1; continue; }
    printf '\ntree: %s\n' "$tree"
    printf '  autoconf.h SCHED_CLASS_EXT=%s DEBUG_INFO_BTF=%s  mtime %s\n' \
        "$(grep -c 'CONFIG_SCHED_CLASS_EXT' "$tree/include/generated/autoconf.h" 2>/dev/null || echo 0)" \
        "$(grep -c 'CONFIG_DEBUG_INFO_BTF' "$tree/include/generated/autoconf.h" 2>/dev/null || echo 0)" \
        "$(date -r "$tree/include/generated/autoconf.h" '+%F %T' 2>/dev/null || echo missing)"
    log="$work/build.$$.log"
    if make -C "$tree" ARCH=arm64 M="$work" modules > "$log" 2>&1; then
        echo "  RESULT: PASS - tree headers match running kernel $kver"
    else
        echo "  RESULT: FAIL - DO NOT BUILD OR STAGE MODULES FROM THIS TREE"
        # GCC prints the tree's own value on the following note line
        grep -E "static assertion failed|note: the comparison reduces to|error:" "$log" \
            | sed -E 's/^.*static assertion failed: //; s/^.*note: the comparison reduces to //; s/^abigate\.c:[0-9]+:[0-9]+: //' \
            | grep -v '^$' | head -20 | sed 's/^/    /'
        rc=1
    fi
done

exit $rc
