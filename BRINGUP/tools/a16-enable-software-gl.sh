#!/usr/bin/env bash
# a16-enable-software-gl.sh -- make GNOME use CPU rendering (llvmpipe), so the desktop stops
# touching msm's GPU path.  Why: starting GNOME oopses the kernel in the GPU private-VM code
#
#   Internal error: Oops: 0000000096000004 [#1]  SMP
#   FSC = 0x04: level 0 translation fault
#   Call trace:
#     msm_gpu_create_private_vm+0x6c/0x1c0 [msm]
#     msm_context_vm+0xcc/0x128 [msm]
#     adreno_get_param+0x40/0x440 [msm]
#     msm_ioctl_get_param+0x58/0xe0 [msm]
#
# ...and the box then wedges (RCU stalls, soft lockups) until it is power-cycled.  The panel and
# the text console are unaffected because fbcon never touches the GPU.
#
# Usage (needs root):
#   sudo bash a16-enable-software-gl.sh            # apply
#   sudo bash a16-enable-software-gl.sh --revert   # undo
#   sudo bash a16-enable-software-gl.sh --check    # read-only
set -u
ENVF=/etc/environment
BAK=/etc/environment.a16-pregl
VARS='LIBGL_ALWAYS_SOFTWARE=1|GALLIUM_DRIVER=llvmpipe|MESA_LOADER_DRIVER_OVERRIDE=kms_swrast'
say(){ printf '%s\n' "$*"; }

mode=apply
for a in "$@"; do case "$a" in --revert) mode=revert;; --check) mode=check;; esac; done

if [ "$mode" = check ]; then
  say "=== /etc/environment now ==="
  sed 's/^/   /' "$ENVF" 2>/dev/null || say "   (missing)"
  say "=== what the running session would use ==="
  say "   LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-<unset>}"
  say "   MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-<unset>}"
  say "   software GL drivers present: $(ls /usr/lib/aarch64-linux-gnu/dri/ 2>/dev/null | grep -cE 'swrast|llvmpipe')"
  say "   an X server is installed: $(dpkg-query -W -f='${Status}' xserver-xorg-core 2>/dev/null | grep -q 'install ok' && echo yes || echo 'no (so Wayland + software GL is the path)')"
  exit 0
fi

if [ "$(id -u)" != 0 ]; then say "FATAL: needs root -- sudo bash $0"; exit 1; fi

if [ "$mode" = revert ]; then
  if [ -f "$BAK" ]; then cp -a "$BAK" "$ENVF"; say "restored $ENVF from $BAK"; else
    say "no $BAK to restore from -- remove the A16 block from $ENVF by hand"; fi
  say "then: sudo systemctl restart gdm"
  exit 0
fi

say "=== a16-enable-software-gl $(date +%Y%m%d-%H%M%S) ==="
[ -f "$BAK" ] || { cp -a "$ENVF" "$BAK" && say "   backup: $BAK"; }
# strip any earlier A16 block, then append the current one
cp -a "$ENVF" /tmp/env.new
sed -i '/^# A16 software GL/,/^# end A16 software GL/d' /tmp/env.new
{
  say_marker="# A16 software GL (added by a16-enable-software-gl.sh)"
  printf '%s\n' "$say_marker"
  printf '%s\n' "$VARS" | tr '|' '\n'
  printf '%s\n' "# end A16 software GL"
} >> /tmp/env.new
install -m 0644 /tmp/env.new "$ENVF" && say "   updated: $ENVF"
say ""
say "now set, for every future session:"
printf '%s\n' "$VARS" | tr '|' '\n' | sed 's/^/   /'
say ""
say "next:"
say "   sudo systemctl restart gdm      # or: sudo systemctl isolate graphical.target"
say ""
say "if the desktop still fails, revert with:  sudo bash $0 --revert  &&  sudo systemctl restart gdm"
