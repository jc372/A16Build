#!/usr/bin/env bash
# a16-bootstrap.sh -- take a fresh Ubuntu install on this machine to the state this repository
#                    describes: build tools, the matching kernel tree, our patches, the modules
#                    built against that kernel, installed, and the boot options set.
#
#   sudo bash scripts/a16-bootstrap.sh --check     # report only, changes nothing (no root needed)
#   sudo bash scripts/a16-bootstrap.sh --all       # everything below, in order
#
# Individual steps, if you prefer to do them one at a time:
#
#   --tools     build tools (apt): compilers, flex/bison, libdw, and pahole (pahole is required)
#   --tree      fetch the exact kernel tree for the running kernel into ~/build
#   --patches   apply the patches we carry (patches/ in this repo) to that tree
#   --config    make the tree's config match the running kernel and verify the module ABI
#   --build     build the modules: gpucc-glymur + gxclkctl-kaanapali, phy-qcom-edp, msm
#   --install   install them into /lib/modules/$(uname -r)/updates and run depmod
#   --options   set the boot options: display parameters, and arm the Bluetooth device tree
#
# Everything is logged to ~/a16-payload/bootstrap-<timestamp>.log, and every step is idempotent.
# Read docs/build.md before changing anything here: a module built with a config that disagrees
# with the kernel has wrong struct offsets and will oops, and the failure looks like a driver bug.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KVER="$(uname -r)"
COMMIT="${A16_COMMIT:-1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3}"
BASE="${A16_BUILD_DIR:-$HOME/build}"
TREE="${A16_TREE:-$BASE/linux-next-${COMMIT:0:12}}"
TARBALL="$BASE/linux-next-${COMMIT:0:12}.tar.gz"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/${COMMIT}.tar.gz"
LOGDIR="$HOME/a16-payload"
LOG="$LOGDIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
PW="$REPO/BRINGUP/tools"
mkdir -p "$LOGDIR" 2>/dev/null
say(){ printf '%s\n' "$*" | tee -a "$LOG"; }
rule(){ say "----------------------------------------------------------------"; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ if [ "$(id -u)" != 0 ]; then say "This step needs root.  Type exactly:"; say; say "    sudo bash $0 $1"; say; exit 1; fi; }

# patches that go into the *tree* (the device-tree and GRUB patches are applied to the machine's
# boot files instead, and the retired ones must never be applied -- see patches/retired/)
TREE_PATCHES=(
  "patches/0006-phy-qcom-edp-split-power-on-sequencing-by-phy-version.patch"
  "patches/0007-phy-qcom-edp-v8-power-on-programming-sequence.patch"
  "patches/0009-drm-msm-dp-force-edp-rate-to-hbr3-experiment.patch"
)

say "=== a16-bootstrap $(date '+%Y-%m-%d %H:%M:%S') ==="
say "repo       : $REPO"
say "kernel     : $KVER"
say "tree       : $TREE"
say "commit     : $COMMIT"
say "log        : $LOG"
rule

do_check(){
  say "== tools"
  for t in gcc make flex bison patch git python3 wget dtc xz; do
    printf '   %-10s %s\n' "$t" "$(have "$t" && command -v "$t" || echo '*** MISSING ***')" | tee -a "$LOG"
  done
  if pahole --version >/dev/null 2>&1; then ph="$(pahole --version 2>/dev/null) ($(command -v pahole))"
  elif [ -x "$HOME/pahole-local/usr/bin/pahole" ]; then ph="$(PATH=$HOME/pahole-local/usr/bin:$PATH LD_LIBRARY_PATH=$HOME/pahole-local/usr/lib/aarch64-linux-gnu pahole --version 2>/dev/null) ($HOME/pahole-local/usr/bin/pahole -- set PATH+LD_LIBRARY_PATH before building)"
  else ph="*** MISSING (builds will be refused) ***"; fi
  printf '   %-10s %s\n' "pahole" "$ph" | tee -a "$LOG"
  say "== tree"
  if [ -f "$TREE/drivers/clk/qcom/gpucc-glymur.c" ]; then say "   present: $TREE"
  else say "   absent : $TREE (run --tree)"; fi
  say "== patches (applied state in the tree)"
  for p in "${TREE_PATCHES[@]}"; do
    f="$REPO/$p"
    if [ ! -f "$f" ]; then printf '   %-60s %s\n' "$(basename "$p")" "MISSING in repo" | tee -a "$LOG"; continue; fi
    if [ ! -d "$TREE" ]; then st="(no tree)"; fi
    if [ -d "$TREE" ]; then
      if ( cd "$TREE" && git apply -R --check -p1 "$f" >/dev/null 2>&1 ); then st="applied"
      elif ( cd "$TREE" && git apply --check -p1 "$f" >/dev/null 2>&1 ); then st="not applied (applies cleanly)"
      else st="applied (or superseded by a later patch in the series)"; fi
    fi
    printf '   %-60s %s\n' "$(basename "$p")" "$st" | tee -a "$LOG"
  done
  say "== config symbols in the tree (these two must be =y; pahole is what keeps them)"
  for o in DEBUG_INFO_BTF SCHED_CLASS_EXT; do
    printf '   %-18s %s\n' "$o" "$(grep -E "^CONFIG_$o=y" "$TREE/.config" 2>/dev/null || echo '*** not set ***')" | tee -a "$LOG"
  done
  say "== modules"
  for m in msm phy-qcom-edp gpucc-glymur gxclkctl-kaanapali; do
    f="$(modinfo -F filename "$m" 2>/dev/null)"
    printf '   %-22s %s\n' "$m" "${f:-not resolvable}" | tee -a "$LOG"
  done
  say "== the kernel's own struct offset, for comparison after any build"
  off="$(bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>/dev/null | python3 -c "
import sys,re
L=sys.stdin.read().split('\n')
for i,l in enumerate(L):
    if re.match(r\"\[\d+\] STRUCT 'task_struct' \", l) and 'size=' in l:
        for m in L[i+1:]:
            if not m.startswith('\t'): break
            g=re.match(r\"\t'(\w+)' type_id=\d+ bits_offset=(\d+)\", m)
            if g and g.group(1)=='thread_pid': print(int(g.group(2))//8); sys.exit()
" 2>/dev/null)"
  say "   thread_pid = ${off:-unknown}   (a module reporting a different value has the wrong config)"
  say "== boot options"
  say "   entries on the ESP, grouped by option:"
  grep 'linux /boot/vmlinuz' /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null \
    | grep -oE 'module_blacklist=[^ ]*' | sort | uniq -c | sed 's/^/      firmware-framebuffer (blacklisted): /' | tee -a "$LOG"
  printf '      built display driver (no blacklist) : %s entries\n' \
    "$(grep -c 'linux /boot/vmlinuz' /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null | awk '{print $1}')" | tee -a "$LOG"
  say "   parameters on the debug/console entries:"
  grep 'linux /boot/vmlinuz' /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null | grep -oE 'drm.debug=[^ ]*|systemd.unit=[^ ]*|consoleblank=[^ ]*' | sort -u | sed 's/^/      /' | tee -a "$LOG"
  say "   this boot is running: $(tr ' ' '\n' < /proc/cmdline | grep -E 'module_blacklist|drm.debug|systemd.unit|consoleblank' | tr '\n' ' ')"
  say "   live DTB: $(sha256sum /boot/glymur-asus-zenbook-a16-ux3607oa.dtb 2>/dev/null | cut -c1-16)  (stock ddb423f8…, BT-patched d8fe1c62…)"
  rule
  say "Read docs/build.md before building anything."
}

do_tools(){
  need_root --tools
  say "== installing build tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y build-essential flex bison libdw-dev libelf-dev libssl-dev bc \
                     git rsync kmod cpio xz-utils device-tree-compiler python3 \
                     pahole libdwarves1 libbpf1 libelf1t64 2>&1 | tail -5 | sed 's/^/   /' | tee -a "$LOG" \
    || { say "   apt failed -- install these by hand:"; say "   build-essential flex bison libdw-dev libelf-dev bc git kmod cpio xz-utils device-tree-compiler python3 pahole"; }
  rule
  for t in gcc make flex bison patch dtc python3; do
    printf '   %-10s %s\n' "$t" "$(have "$t" && echo ok || echo '*** MISSING ***')" | tee -a "$LOG"
  done
  say "   pahole    : $(pahole --version 2>/dev/null || echo '*** MISSING -- builds will be refused ***')"
}

do_tree(){
  if [ -f "$TREE/drivers/clk/qcom/gpucc-glymur.c" ]; then say "== tree already present: $TREE"; return 0; fi
  mkdir -p "$BASE"
  say "== fetching the kernel tree for commit $COMMIT"
  if [ ! -s "$TARBALL" ]; then
    python3 - "$URL" "$TARBALL" <<'PY' | sed 's/^/   /' | tee -a "$LOG"
import sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux aarch64)"})
with urllib.request.urlopen(req, timeout=600) as r, open(out, "wb") as f:
    total = 0
    while True:
        chunk = r.read(1 << 20)
        if not chunk:
            break
        f.write(chunk); total += len(chunk)
print("downloaded %d MB" % (total >> 20))
PY
  else say "   using existing $TARBALL"; fi
  say "== extracting to $TREE (about 1.8 GB)"
  mkdir -p "$TREE"
  tar -xzf "$TARBALL" -C "$TREE" --strip-components=1 2>&1 | tail -3 | sed 's/^/   /' | tee -a "$LOG"
  printf '%s\n' "$COMMIT" > "$TREE/.a16-commit"
  [ -f "$TREE/drivers/clk/qcom/gpucc-glymur.c" ] \
    && say "   ok: gpucc-glymur.c present" \
    || { say "   FATAL: extraction did not produce the expected tree"; exit 1; }
}

do_patches(){
  say "== applying our patches to the tree"
  [ -f "$TREE/Makefile" ] || { say "   no tree at $TREE -- run --tree first"; exit 1; }
  cd "$TREE" || exit 1
  for p in "${TREE_PATCHES[@]}"; do
    f="$REPO/$p"
    [ -f "$f" ] || { say "   MISSING: $p"; continue; }
    name="$(basename "$p")"
    if git apply -p1 -R --check "$f" >/dev/null 2>&1; then say "   $name: already applied"; continue; fi
    if git apply -p1 --check "$f" >/dev/null 2>&1; then
      git apply -p1 "$f" >>"$LOG" 2>&1 && say "   $name: applied" || say "   $name: FAILED -- see $LOG"
    elif patch -p1 --dry-run -f < "$f" >/dev/null 2>&1; then
      patch -p1 -f < "$f" >>"$LOG" 2>&1 && say "   $name: applied (via patch)" || say "   $name: FAILED -- see $LOG"
    else
      say "   $name: does not apply cleanly (tree already changed?) -- check by hand"
    fi
  done
  cd "$REPO" || exit 1
  say "   note: patches/0008 (PUSH_IDLE) is *not* applied by default; it matters for DPMS paths"
  say "         on this SoC and can be added with git apply if you are debugging the display."
}

do_config(){
  say "== making the tree's config match the running kernel (and verifying the ABI)"
  export A16_TREE="$TREE"
  bash "$PW/a16-fix-build-config.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
}

do_build(){
  say "== building modules (this takes a few minutes)"
  say "-- 1/3 gpucc-glymur + gxclkctl-kaanapali (also sets up Module.symvers and modules_prepare)"
  bash "$PW/a16-build-gpucc-native.sh" --build 2>&1 | sed 's/^/   /' | tee -a "$LOG" | tail -20
  say "-- 2/3 phy-qcom-edp"
  ( cd "$TREE" && make --no-print-directory ARCH=arm64 M=drivers/phy/qualcomm clean >/dev/null 2>&1; \
    make --no-print-directory -j"$(nproc)" ARCH=arm64 M=drivers/phy/qualcomm phy-qcom-edp.ko ) >>"$LOG" 2>&1 \
    && say "   built" || say "   FAILED -- see $LOG"
  say "-- 3/3 msm"
  ( cd "$TREE" && make --no-print-directory ARCH=arm64 M=drivers/gpu/drm/msm clean >/dev/null 2>&1; \
    make --no-print-directory -j"$(nproc)" ARCH=arm64 M=drivers/gpu/drm/msm msm.ko ) >>"$LOG" 2>&1 \
    && say "   built" || say "   FAILED -- see $LOG"
  rule
  for ko in \
    "$TREE/drivers/clk/qcom/gpucc-glymur.ko" \
    "$TREE/drivers/clk/qcom/gxclkctl-kaanapali.ko" \
    "$TREE/drivers/phy/qualcomm/phy-qcom-edp.ko" \
    "$TREE/drivers/gpu/drm/msm/msm.ko"; do
    if [ -f "$ko" ]; then
      printf '   %-24s %8s bytes  vermagic %s\n' "$(basename "$ko")" "$(stat -c %s "$ko")" "$(modinfo -F vermagic "$ko" | cut -d' ' -f1)" | tee -a "$LOG"
    else
      printf '   %-24s MISSING\n' "$(basename "$ko")" | tee -a "$LOG"
    fi
  done
}

do_install(){
  need_root --install
  say "== installing into /lib/modules/$KVER/updates"
  local list=()
  for ko in \
    "$TREE/drivers/clk/qcom/gpucc-glymur.ko" \
    "$TREE/drivers/clk/qcom/gxclkctl-kaanapali.ko" \
    "$TREE/drivers/phy/qualcomm/phy-qcom-edp.ko" \
    "$TREE/drivers/gpu/drm/msm/msm.ko"; do
    [ -f "$ko" ] && list+=("$ko")
  done
  [ "${#list[@]}" -gt 0 ] || { say "   nothing built -- run --build first"; exit 1; }
  bash "$PW/a16-install-gpucc-module.sh" "${list[@]}" 2>&1 | sed 's/^/   /' | tee -a "$LOG"
  depmod -a "$KVER"
  rule
  for m in msm phy-qcom-edp gpucc-glymur gxclkctl-kaanapali; do
    printf '   %-22s %s\n' "$m" "$(modinfo -F filename "$m" 2>/dev/null)" | tee -a "$LOG"
  done
  say "   A reboot is needed for a new msm/phy to be used."
}

do_options(){
  need_root --options
  say "== boot options: the display parameters"
  A16_PARAMS="consoleblank=0" bash "$PW/a16-drm-debug-entry.sh" remove inline >/dev/null 2>&1
  A16_PARAMS="consoleblank=0" bash "$PW/a16-drm-debug-entry.sh" arm 2>&1 | sed 's/^/   /' | tee -a "$LOG"
  say ""
  say "== boot options: the Bluetooth device tree"
  src="$REPO/firmware/glymur-asus-zenbook-a16-ux3607oa-a16bt.dtb"
  if [ -f "$src" ]; then
    for d in /boot/glymur-a16-bt-test.dtb /boot/efi/a16boot/glymur-a16-bt-test.dtb; do
      install -D -m 0644 "$src" "$d" 2>/dev/null && say "   placed: $d"
    done
    sha256sum "$src" | awk '{print $1}' > /boot/glymur-a16-bt-test.dtb.sha256 2>/dev/null
    bash "$PW/a16-bt-arm.sh" 2>&1 | sed 's/^/   /' | tee -a "$LOG" | tail -12
  else
    say "   $src missing -- skipping the BT device tree"
  fi
  rule
  say "The machine now boots with the built display driver and the BT device tree."
  say "For the other display option (firmware framebuffer), put this on the command line:"
  say "   module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20"
  say "See docs/boot-options.md for how the two options are selected."
}

mode="${1:---all}"
case "$mode" in
  --check)   do_check ;;
  --tools)   do_tools ;;
  --tree)    do_tree ;;
  --patches) do_patches ;;
  --config)  do_config ;;
  --build)   do_build ;;
  --install) do_install ;;
  --options) do_options ;;
  --all)
    need_root --all
    do_tools; rule; do_tree; rule; do_patches; rule; do_config; rule; do_build; rule; do_install; rule; do_options; rule
    say "=== done.  Reboot to use the freshly installed modules.  docs/boot-options.md explains     ==="
    say "=== which option the machine will come up in, and how to read the log afterwards.         ==="
    ;;
  -h|--help|--list)
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) say "unknown option: $mode"; sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
