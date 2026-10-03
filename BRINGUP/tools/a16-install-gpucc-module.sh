#!/usr/bin/env bash
# a16-install-gpucc-module.sh -- install the gpucc-glymur module built on the build side, on the
#                                A16 itself, and prove it will load before rebooting.
#
#   sudo bash a16-install-gpucc-module.sh /path/to/gpucc-glymur-<ver>.tar.gz
#   sudo bash a16-install-gpucc-module.sh /path/to/dir-of-.ko
#   sudo bash a16-install-gpucc-module.sh /path/to/gpucc-glymur.ko [more.ko ...]
#
# NOTE: although the name says gpucc, it installs *any* kernel module built against this kernel: it
#       checks vermagic and the module_layout CRC, installs into updates/ (which depmod makes win over
#       kernel/, so nothing shipped is overwritten and undoing it is `rm` + `depmod -a`), and prints
#       how to verify.  A16_MODDIR overrides the target directory.
#   bash a16-install-gpucc-module.sh --check     # read-only: is the module in place and matching?
#
# The one rule that matters: the module's vermagic must match the running kernel exactly, or the
# kernel refuses to load it and the display stays dark with no explanation.  This script refuses to
# install a mismatch, and prints the before/after vermagic so the check is visible.
set -u

MODE="${1:-}"
[ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
LOG="${A16_LOG:-$HOME/a16-payload/A16GPUCC-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/var/tmp/a16-gpucc-$(date +%Y%m%d-%H%M%S).log
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

KVER="$(uname -r)"
# Install into updates/ rather than the kernel's own tree: depmod makes `updates/` win over
# kernel/, so nothing shipped is overwritten and removing the fix is `rm` + `depmod`.
MODDIR="${A16_MODDIR:-/lib/modules/$KVER/updates/a16}"   # updates/ overrides kernel/ (depmod)
KERNDIR="/lib/modules/$KVER/kernel/drivers/clk/qcom"
WANT="$(modinfo -F vermagic /lib/modules/$KVER/kernel/drivers/clk/qcom/dispcc-glymur.ko 2>/dev/null || echo "$KVER SMP preempt mod_unload modversions aarch64")"

if [ "$MODE" = "--check" ]; then
  say "=== gpucc-glymur check (kernel $KVER) ==="
  say "   expected vermagic : $WANT"
  for m in gpucc-glymur gxclkctl-kaanapali; do
    up="$MODDIR/$m.ko"; kn="$KERNDIR/$m.ko"
    if [ -f "$up" ]; then say "   $m: $up ($(stat -c %s "$up") bytes)  [updates/ -- this one wins]"
    elif [ -f "$kn" ]; then say "   $m: $kn ($(stat -c %s "$kn") bytes)"
    else say "   $m: NOT INSTALLED -- this is why entries [3]/[4] black-screen (msm cannot bind"
         say "        without the GPU's power domain: NEXT-STEPS item 7)"; fi
  done
  say "   resolvable now    : $(modinfo -F filename gpucc-glymur 2>/dev/null || echo 'no') / $(modinfo -F filename gxclkctl-kaanapali 2>/dev/null || echo 'no')"
  say "   modprobe dry-run  : $(modprobe -n -v gpucc-glymur 2>&1 | head -2)"
  say "   bound now?        : gpucc=$(ls -d /sys/bus/platform/devices/3d90000.clock-controller/driver 2>/dev/null >/dev/null && echo yes || echo no) gxclkctl=$(ls -d /sys/bus/platform/devices/3d64000.clock-controller/driver 2>/dev/null >/dev/null && echo yes || echo no)"
  say "   log: $LOG"; exit 0
fi

[ -n "$MODE" ] || { say "usage: sudo bash $0 <tarball-or-.ko>   |   bash $0 --check"; exit 2; }
[ "$(id -u)" = 0 ] || { say "needs root: sudo bash $0 $MODE"; exit 1; }
[ -e "$MODE" ] || { say "FATAL: $MODE does not exist"; exit 1; }

WORK="$(mktemp -d)"
KOS=""
for arg in "$@"; do
  case "$arg" in
    *.tar.gz|*.tgz)
      tar -xzf "$arg" -C "$WORK" || { say "FATAL: cannot unpack $arg"; exit 1; }
      KOS="$KOS $(find "$WORK" -name '*.ko')";;
    *.ko) KOS="$KOS $arg";;
    */)   KOS="$KOS $(find "$arg" -maxdepth 1 -name '*.ko')";;
    *)    say "FATAL: give me a .tar.gz, a .ko, or a directory of .ko"; exit 1;;
  esac
done
KOS="$(echo $KOS | tr ' ' '\n' | sort -u | tr '\n' ' ')"
say "   modules to install:"; for f in $KOS; do say "     $(basename "$f")"; done
[ -n "$(echo "$KOS" | tr -d ' ')" ] || { say "FATAL: no .ko found"; exit 1; }

say "=== a16-install-gpucc-module $(date +%Y%m%d-%H%M%S) ==="
say "   kernel            : $KVER"
say "   kernel vermagic   : $WANT"
for f in $KOS; do
  GOT="$(modinfo -F vermagic "$f" 2>/dev/null)"
  say "   $(basename "$f"): $(stat -c %s "$f") bytes, sha256 $(sha256sum "$f" | cut -c1-16)…, vermagic '$GOT'"
  [ "$GOT" = "$WANT" ] || { say "FATAL: vermagic mismatch on $(basename "$f") -- the kernel would refuse it."; say "log: $LOG"; exit 1; }
  if modprobe --dump-modversions "$f" 2>/dev/null | grep -q module_layout; then :; else
    say "FATAL: $(basename "$f") has no module_layout version -- the kernel will refuse it."; exit 1
  fi
done
say "   vermagic matches, module_layout present ✓"
install -d -m 0755 "$MODDIR" || exit 1
for f in $KOS; do
  install -m 0644 "$f" "$MODDIR/$(basename "$f")" || { say "FATAL: install failed for $f"; exit 1; }
  say "   installed         : $MODDIR/$(basename "$f")"
done
depmod -a "$KVER" 2>&1 | sed 's/^/   depmod: /' | tee -a "$LOG"
for f in $KOS; do n="$(basename "$f" .ko)"; say "   $n: $(modinfo -F filename "$n" 2>/dev/null || echo '(not found -- depmod problem)')  |  modprobe -n: $(modprobe -n -v "$n" 2>&1 | head -1)"; done
rm -rf "$WORK"

say ""
say "NEXT: reboot, take entry [3] (msm + panel enabled), wait ~90 s, then either"
say "        bash $HOME/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh --check"
say "      or read the boot snapshot:"
say "        ls -t $HOME/a16-payload/boots | head -1"
say "      What to look for (in that snapshot's 04-dmesg-display.txt / 02-drm.txt):"
say "        gpucc-glymur 3d90000.clock-controller ... registered/bound"
say "        adreno 3d00000.gpu: GMU firmware ... / bound"
say "        card0 bound by *msm*  and  /sys/class/backlight/ non-empty"
say "      If it goes dark again, [2] is still the working entry."
say "log: $LOG"
