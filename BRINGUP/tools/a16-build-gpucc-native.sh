#!/usr/bin/env bash
# a16-build-gpucc-native.sh -- build the missing gpucc-glymur module ON THE A16 ITSELF, natively.
#
#   bash a16-build-gpucc-native.sh --fetch    # no root, no compiler: get the exact tree + config
#   bash a16-build-gpucc-native.sh --build    # after the toolchain exists: build + verify the .ko
#   bash a16-build-gpucc-native.sh --check    # read-only: what state is the build in?
#
# Why this works without the original build host:
#   * the tree     -- the bundle we installed carries metadata/linux-next-commit.txt, so the exact
#                     commit is known: 1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3.  git.kernel.org
#                     serves a source snapshot of any commit, so we fetch exactly that tree.
#   * the config   -- metadata/kernel.config is byte-identical to /boot/config-<ver>; we use it.
#   * vermagic    -- the tree has no .git, so scripts/setlocalversion cannot append "-next-<date>";
#                     we pass LOCALVERSION="$(suffix)" and *verify* `make kernelrelease`.
#   * MODVERSIONS  -- the module must carry the kernel's symbol CRCs (module_layout is mandatory).
#                     The installed modules carry those CRCs in their __versions sections, so we
#                     harvest them into a Module.symvers.  A sibling CC module imports only ~14
#                     symbols and the set is well covered.
#   * BTF/DWARF    -- the stock config has CONFIG_DEBUG_INFO_BTF=y.  An earlier version of this
#                     script turned it off "because pahole and a vmlinux are missing".  That was
#                     wrong and expensive: SCHED_CLASS_EXT depends on DEBUG_INFO_BTF, so turning BTF
#                     off silently drops sched_ext, which removes the embedded `struct
#                     sched_ext_entity scx` from task_struct and shifts every later field by 320
#                     bytes.  Every module built that way oopsed in whichever function first
#                     dereferenced a task field.  pahole IS needed; if it is missing this script
#                     stops rather than producing modules with the wrong ABI.  (Module BTF itself is
#                     optional -- the build prints "Skipping BTF generation ... vmlinux" and carries
#                     on, which is fine.)
set -u

KVER="$(uname -r)"
COMMIT="${A16_COMMIT:-1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3}"
BASE="${A16_BUILD_DIR:-$HOME/build}"
TREE="${A16_TREE:-$BASE/linux-next-${COMMIT:0:12}}"
TARBALL="$BASE/linux-next-${COMMIT:0:12}.tar.gz"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/${COMMIT}.tar.gz"
SYMVERS="$TREE/Module.symvers"
LOGDIR="$HOME/a16-payload"
LOG="$LOGDIR/A16GPUCC-native-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOGDIR" 2>/dev/null
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== a16-build-gpucc-native $(date +%Y%m%d-%H%M%S) ==="
say "kernel (running) : $KVER"
say "tree commit      : $COMMIT"
say "tree dir         : $TREE"
say "log              : $LOG"
say ""

# ---------------------------------------------------------------- suffix for the version string
tree_base_version() {   # 7.3.0-rc3  from the tree's Makefile
  local v p s e
  v=$(sed -n 's/^VERSION *= *//p' "$TREE/Makefile" | head -1)
  p=$(sed -n 's/^PATCHLEVEL *= *//p' "$TREE/Makefile" | head -1)
  s=$(sed -n 's/^SUBLEVEL *= *//p' "$TREE/Makefile" | head -1)
  e=$(sed -n 's/^EXTRAVERSION *= *//p' "$TREE/Makefile" | head -1)
  printf '%s.%s.%s%s' "$v" "$p" "$s" "$e"
}

# Run a make step: full output to the log, tail to the screen, non-zero = fatal.
# (An earlier version piped make through `tail` into the log, which threw away the actual error:
#  gendwarfksyms needed dwarf.h and all we had was the last four lines.  The log is the evidence.)
run_make() {
  local desc="$1"; shift
  local before; before=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  say "   make $desc …"
  ( cd "$TREE" && make --no-print-directory "$@" ) >>"$LOG" 2>&1
  local rc=$?
  tail -n +"$((before + 1))" "$LOG" | tail -12 | sed 's/^/   | /'
  if [ "$rc" -ne 0 ]; then
    say "FATAL: make $desc failed (rc=$rc). Full output: $LOG"
    say "       host-dep reminders: dwarf.h (gendwarfksyms, needed because the kernel is built with"
    say "       CONFIG_EXTENDED_MODVERSIONS=y) -> sudo apt install -y libdw-dev"
    exit 1
  fi
}

case "${1:---fetch}" in
# ------------------------------------------------------------------------------------------ fetch
--fetch)
  say "== fetch $URL"
  mkdir -p "$BASE" || exit 1
  if [ -f "$TARBALL" ]; then say "   already downloaded: $TARBALL ($(stat -c %s "$TARBALL") bytes)"; else
    wget -c --progress=dot:giga -O "$TARBALL" "$URL" 2>&1 | tail -3 | sed 's/^/   /' | tee -a "$LOG"
    [ -s "$TARBALL" ] || { say "FATAL: download failed"; exit 1; }
  fi
  say "   size: $(du -h "$TARBALL" | cut -f1)"
  say "== extract"
  if [ -d "$TREE" ]; then say "   already extracted: $TREE"; else
    mkdir -p "$TREE" || exit 1
    tar -xzf "$TARBALL" -C "$TREE" --strip-components=1 || { say "FATAL: extract failed"; exit 1; }
  fi
  [ -f "$TREE/Makefile" ] || { say "FATAL: $TREE has no Makefile"; exit 1; }
  say "   files: $(find "$TREE" -type f | wc -l)   size: $(du -sh "$TREE" | cut -f1)"
  say "   tree version  : $(tree_base_version)   (needs LOCALVERSION=\"${KVER#$(tree_base_version)}\")"

  say "== the driver the build left out"
  if [ -f "$TREE/drivers/clk/qcom/gpucc-glymur.c" ]; then
    say "   drivers/clk/qcom/gpucc-glymur.c: present ✓  ($(wc -l < "$TREE/drivers/clk/qcom/gpucc-glymur.c") lines)"
  else
    say "   FATAL: drivers/clk/qcom/gpucc-glymur.c is NOT in this commit -- the commit is wrong"; exit 1
  fi
  grep -qE '^config CLK_GLYMUR_GPUCC' "$TREE/drivers/clk/qcom/Kconfig" \
    && say "   Kconfig symbol: config CLK_GLYMUR_GPUCC ✓" || { say "   FATAL: symbol missing from Kconfig"; exit 1; }
  say "   this one symbol builds BOTH drivers that failed in the log:"; grep -E 'CONFIG_CLK_GLYMUR_GPUCC' "$TREE/drivers/clk/qcom/Makefile" | sed 's/^/     /'
  grep -qE 'CLK_GLYMUR_GPUCC' "$TREE/drivers/clk/qcom/Makefile" \
    && say "   Makefile line : $(grep -E 'CLK_GLYMUR_GPUCC' "$TREE/drivers/clk/qcom/Makefile")" \
    || say "   NOTE: no Makefile line for the symbol (a module cannot be built without it)"

  say "== .config: the running kernel's own config, with the one symbol turned on"
  cp -a "/boot/config-$KVER" "$TREE/.config" || { say "FATAL: no /boot/config-$KVER"; exit 1; }
  say "   before: $(grep -E '^#? ?CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config")"
  "$TREE/scripts/config" --file "$TREE/.config" --module CLK_GLYMUR_GPUCC
  # Do NOT turn DEBUG_INFO_BTF off: SCHED_CLASS_EXT depends on it, and without sched_ext the
  # struct task_struct layout in our modules differs from the kernel's (thread_pid 1824 vs 2144).
  # pahole is required for this; it is checked before the build starts.
  "$TREE/scripts/config" --file "$TREE/.config" --enable DEBUG_INFO_BTF
  say "   after : $(grep -E '^CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config")"
  say "   btf   : $(grep -E '^#? ?CONFIG_DEBUG_INFO_BTF' "$TREE/.config" | head -1)"

  say "== Module.symvers: harvest the kernel's symbol CRCs from the installed modules"
  say "   (the module must carry the kernel's CRC for module_layout; modpost takes the rest from here)"
  tmp="$(mktemp)"
  for k in $(find "/lib/modules/$KVER" -name '*.ko'); do
    modprobe --dump-modversions "$k" 2>/dev/null
  done | awk '{printf "%s\t%s\t%s\tEXPORT_SYMBOL\t\n", $1, $2, "vmlinux"}' | sort -u > "$tmp"
  # NOTE the trailing tab: modpost's read_dump() wants five fields
  # (0xcrc<TAB>symbol<TAB>module<TAB>export<TAB>namespace) and fails with
  # "parse error in symbol dump file" if the namespace field is absent.
  mv "$tmp" "$SYMVERS"
  cp -f "$SYMVERS" "$SYMVERS.a16harvest"   # the M= module build rewrites Module.symvers from the
                                           # built modules (a handful of exports) -- restore below
  say "   symbols with CRCs: $(wc -l < "$SYMVERS")"
  grep -q 'module_layout' "$SYMVERS" && say "   module_layout: present ✓" \
    || say "   WARNING: module_layout missing -- the kernel will refuse the module"
  for s in module_layout qcom_cc_probe clk_branch2_ops __platform_driver_register regmap_update_bits_base; do
    printf '   sanity %-28s %s\n' "$s" "$(grep -E "^0x[0-9a-f]+[[:space:]]+$s([[:space:]]|$)" "$SYMVERS" | head -1 | cut -f1)"
  done

  say ""
  say "NEXT (needs your password, one command):"
  say "   sudo apt install -y build-essential flex bison libssl-dev libelf-dev libdw-dev libncurses-dev bc"
  say "then:"
  say "   bash $0 --build"
  say "log: $LOG"
  ;;

# ------------------------------------------------------------------------------------------ build
--build)
  [ -d "$TREE" ] || { say "FATAL: run --fetch first ($TREE missing)"; exit 1; }
  miss=""
  for t in gcc make flex bison; do command -v "$t" >/dev/null || miss="$miss $t"; done
  if ! pahole --version >/dev/null 2>&1; then
    say "FATAL: pahole is missing, and building without it silently produces modules whose"
    say "       struct layouts disagree with the kernel's (see docs/build.md).  Install it:"
    say "         sudo apt install -y pahole libdwarves1 libbpf1 libelf1t64"
    say "       or extract it locally without root:"
    say "         cd /tmp && for p in pahole libdwarves1 libbpf1 libelf1t64; do apt-get download \$p; done"
    say "         for d in *.deb; do dpkg-deb -x \$d ~/pahole-local; done"
    say "         export PATH=~/pahole-local/usr/bin:\$PATH"
    say "         export LD_LIBRARY_PATH=~/pahole-local/usr/lib/aarch64-linux-gnu:\$LD_LIBRARY_PATH"
    exit 1
  fi
  say "   pahole        : $(pahole --version)"
  [ -f /usr/include/dwarf.h ]    || miss="$miss libdw-dev(dwarf.h)"
  [ -f /usr/include/libelf.h ]   || miss="$miss libelf-dev(libelf.h)"
  [ -f /usr/include/openssl/opensslv.h ] || miss="$miss libssl-dev"
  if [ -n "$miss" ]; then
    say "FATAL: missing build prerequisites:$miss"
    say "   sudo apt install -y build-essential flex bison libssl-dev libelf-dev libdw-dev libncurses-dev bc"
    exit 1
  fi

  say "== settle the config and the version string"
  LOCALV=""
  got="$(make -C "$TREE" --no-print-directory ARCH=arm64 kernelrelease 2>/dev/null | tail -1)"
  say "   tree reports        : $got"
  if [ "$got" != "$KVER" ]; then
    SUFFIX="${KVER#$got}"
    say "   trying LOCALVERSION=$SUFFIX"
    got2="$(make -C "$TREE" --no-print-directory ARCH=arm64 LOCALVERSION="$SUFFIX" kernelrelease 2>/dev/null | tail -1)"
    say "   with LOCALVERSION   : $got2"
    [ "$got2" = "$KVER" ] || { say "FATAL: cannot make the tree report $KVER (got '$got2')"; exit 1; }
    LOCALV="LOCALVERSION=$SUFFIX"
  fi
  make -C "$TREE" --no-print-directory ARCH=arm64 $LOCALV olddefconfig >/dev/null 2>>"$LOG"
  got="$(make -C "$TREE" --no-print-directory ARCH=arm64 $LOCALV kernelrelease 2>/dev/null | tail -1)"
  say "   after olddefconfig  : $got   (want $KVER)"
  [ "$got" = "$KVER" ] || { say "FATAL: version string mismatch -- a module built with the wrong release will not load"; exit 1; }
  say "   symbol              : $(grep -E '^CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config")"

  if [ -f "$SYMVERS.a16harvest" ]; then
    cp -f "$SYMVERS.a16harvest" "$SYMVERS"
    say "   symvers restored to the harvested $(wc -l < "$SYMVERS") CRCs (an M= build rewrites it)"
  fi

  say "== prepare (headers + host tools; no vmlinux needed)"
  run_make "modules_prepare" ARCH=arm64 $LOCALV modules_prepare

  say "== build only drivers/clk/qcom"
  run_make "modules in drivers/clk/qcom" ARCH=arm64 $LOCALV -j"$(nproc)" M=drivers/clk/qcom modules KBUILD_MODPOST_WARN=1

  if [ -f "$SYMVERS.a16harvest" ] && [ "$(wc -l < "$SYMVERS")" -lt 1000 ]; then
    say "   note: the build rewrote Module.symvers ($(wc -l < "$SYMVERS") lines); harvesting copy kept at"
    say "         $SYMVERS.a16harvest and restored for the next run"
    cp -f "$SYMVERS.a16harvest" "$SYMVERS"
  fi

  say "== verify the .ko files"
  WANT="$(modinfo -F vermagic /lib/modules/$KVER/kernel/drivers/clk/qcom/dispcc-glymur.ko 2>/dev/null)"
  KERNEL_ML="$(modprobe --dump-modversions /lib/modules/$KVER/kernel/drivers/clk/qcom/dispcc-glymur.ko 2>/dev/null | awk '$2=="module_layout"{print $1}')"
  ok=0
  for KO in "$TREE/drivers/clk/qcom/gpucc-glymur.ko" "$TREE/drivers/clk/qcom/gxclkctl-kaanapali.ko"; do
    [ -f "$KO" ] || { say "   MISSING: $(basename "$KO")"; continue; }
    v="$(modinfo -F vermagic "$KO" 2>/dev/null)"
    ml="$(modprobe --dump-modversions "$KO" 2>/dev/null | awk '$2=="module_layout"{print $1}')"
    nv="$(modprobe --dump-modversions "$KO" 2>/dev/null | wc -l)"
    say "   $(basename "$KO"): $(stat -c %s "$KO") bytes"
    say "      vermagic      : $v"
    say "      module_layout : ${ml:-MISSING}   (kernel's: $KERNEL_ML)"
    say "      imports with versions: $nv"
    [ "$v" = "$WANT" ] && [ "$ml" = "$KERNEL_ML" ] && ok=$((ok+1))
  done
  say "   $ok of 2 modules verified (vermagic + module_layout both matching)"

  # The ABI check that would have caught the config mistake: the kernel's own offset for a
  # task_struct field (from its BTF) against the one our module was compiled with (from its DWARF).
  koff="$(bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>/dev/null | python3 -c "
import sys,re
lines=sys.stdin.read().split('\n')
for i,l in enumerate(lines):
    if re.match(r\"\[\d+\] STRUCT 'task_struct' \", l) and 'size=' in l:
        for m in lines[i+1:]:
            if not m.startswith('\t'): break
            g=re.match(r\"\t'(\w+)' type_id=\d+ bits_offset=(\d+)\", m)
            if g and g.group(1)=='thread_pid': print(int(g.group(2))//8); sys.exit()
" 2>/dev/null)"
  for KO in "$TREE"/drivers/clk/qcom/gpucc-glymur.ko "$TREE"/drivers/clk/qcom/gxclkctl-kaanapali.ko; do
    [ -f "$KO" ] || continue
    moff="$(gdb -batch -ex 'ptype /o struct task_struct' "$KO" 2>/dev/null | awk '/thread_pid;/{print $2; exit}')"
    if [ -n "$koff" ] && [ -n "$moff" ]; then
      if [ "$moff" = "$koff" ]; then say "   ABI           : thread_pid kernel=$koff module=$moff  ✓"
      else say "   FATAL: $(basename "$KO") was built with a different struct layout than the kernel"
           say "          (thread_pid kernel=$koff module=$moff).  Do NOT install it."
           say "          See docs/build.md -- the config must keep DEBUG_INFO_BTF=y and SCHED_CLASS_EXT=y."
           exit 1
      fi
    else
      say "   ABI           : could not compare thread_pid offsets (kernel=$koff module=$moff)"
    fi
  done
  [ "$ok" -ge 1 ] || { say "FATAL: nothing verified -- do not install"; exit 1; }

  say ""
  say "NEXT (needs your password) -- both modules come from the one symbol:"
  say "   sudo bash $HOME/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh $TREE/drivers/clk/qcom/"
  say "   then reboot into [3]"
  say "log: $LOG"
  ;;

# ------------------------------------------------------------------------------------------ check
--check)
  say "=== gpucc-glymur native build state ==="
  say "   tarball : $([ -s "$TARBALL" ] && echo "$TARBALL ($(du -h "$TARBALL" | cut -f1))" || echo 'not downloaded')"
  say "   tree    : $([ -f "$TREE/Makefile" ] && echo "$TREE ($(find "$TREE" -type f 2>/dev/null | wc -l) files)" || echo 'not extracted')"
  say "   .config : $([ -f "$TREE/.config" ] && grep -E '^CONFIG_CLK_GLYMUR_GPUCC' "$TREE/.config" || echo '(no .config yet)')"
  say "   symvers : $([ -f "$SYMVERS" ] && echo "$(wc -l < "$SYMVERS") symbols" || echo 'not harvested')"
  say "   .ko     : $([ -f "$TREE/drivers/clk/qcom/gpucc-glymur.ko" ] && echo "$TREE/drivers/clk/qcom/gpucc-glymur.ko ($(stat -c %s "$TREE/drivers/clk/qcom/gpucc-glymur.ko") bytes)" || echo 'not built yet')"
  say "   toolchain: $(command -v gcc >/dev/null && gcc --version | head -1 || echo 'MISSING -> sudo apt install -y build-essential flex bison libssl-dev libelf-dev libdw-dev libncurses-dev bc')"
  say "   installed: $([ -f /lib/modules/$KVER/kernel/drivers/clk/qcom/gpucc-glymur.ko ] && echo YES || echo 'NO (the black screen)')"
  say "log: $LOG"
  ;;
*) say "usage: bash $0 [--fetch|--build|--check]"; exit 2 ;;
esac
