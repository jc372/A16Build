#!/usr/bin/env bash
# a16-x11-desktop.sh -- get a usable GNOME desktop on the panel WITHOUT the GPU.
#
# Why X11 and not Wayland: this script exists for the case where the adreno gen8 render path is
# broken and the GPU cannot be used -- it forces the X server, and the desktop, onto software
# rendering.  That was necessary while gnome-shell's first GPU submit oopsed:
#
# Historical note: the GPU is FIXED on this machine as of the t2 release (the two HFI exchanges
# gen80100_gmu.bin v5.2.38 will not ack are gated for this chip).  On the current kernel a
# Wayland session with the GPU works, so this script is a fallback rather than a requirement.
#
#     Internal error: Oops: 0000000096000004 [#1]  SMP
#     CPU: 9 PID: 4809 Comm: gnome-shell
#     pc : msm_ioctl_gem_submit+0x184/0x1b60 [msm]      (x0=1, x1=0, x2=0 -> NULL deref)
#
# ...and the box wedges until power-cycled.  (The MSM_GET_PARAM oops before it is already fixed by
# patches/0010; this is the next one, and it is a GPU bring-up problem, not a display problem.)
#
# On X11, gnome-shell renders with GLX -> libGL -> llvmpipe when LIBGL_ALWAYS_SOFTWARE=1, so the
# GPU is never opened at all.  This script also tells the X server not to accelerate, so nothing
# reaches msm's render path even by accident.
#
# Usage (needs root):   sudo bash a16-x11-desktop.sh          # apply + restart gdm
#                       sudo bash a16-x11-desktop.sh --check  # read-only
#                       sudo bash a16-x11-desktop.sh --revert # undo
set -u
LOG=/home/jc/a16-payload/x11-desktop-$(date +%Y%m%d-%H%M%S).log
mkdir -p /home/jc/a16-payload 2>/dev/null
exec > >(tee -a "$LOG") 2>&1
say(){ printf '%s\n' "$*"; }
rule(){ say "----------------------------------------------------------------"; }
mode=apply
for a in "$@"; do case "$a" in --revert) mode=revert;; --check) mode=check;; esac; done

[ "$mode" = check ] && {
  say "=== a16 X11 desktop: current state ==="
  say "   Xorg binary        : $(ls /usr/lib/xorg/Xorg /usr/bin/Xorg 2>/dev/null | head -1 || echo 'NOT installed')"
  say "   xsessions          : $(ls /usr/share/xsessions/ 2>/dev/null | tr '\n' ' ' || echo none)"
  say "   gdm WaylandEnable  : $(grep -h 'WaylandEnable' /etc/gdm3/custom.conf 2>/dev/null || echo 'not set (Wayland is the default)')"
  say "   X no-accel config  : $(ls /etc/X11/xorg.conf.d/20-a16-noaccel.conf 2>/dev/null || echo 'not written')"
  say "   software GL env    : $(grep -c 'LIBGL_ALWAYS_SOFTWARE=1' /etc/environment 2>/dev/null) line(s) in /etc/environment"
  exit 0
}

if [ "$(id -u)" != 0 ]; then say "FATAL: needs root -- type:  sudo bash ~/a16.sh x11"; exit 1; fi

if [ "$mode" = revert ]; then
  say "=== reverting the X11 desktop setup ==="
  [ -f /etc/X11/xorg.conf.d/20-a16-noaccel.conf.a16.bak ] && mv -f /etc/X11/xorg.conf.d/20-a16-noaccel.conf.a16.bak /etc/X11/xorg.conf.d/20-a16-noaccel.conf
  rm -f /etc/X11/xorg.conf.d/20-a16-noaccel.conf /usr/share/xsessions/ubuntu-a16-xorg.desktop
  [ -f /etc/gdm3/custom.conf.a16.bak ] && cp -a /etc/gdm3/custom.conf.a16.bak /etc/gdm3/custom.conf
  [ -f /etc/environment.a16-pregl ] && cp -a /etc/environment.a16-pregl /etc/environment
  say "   removed the X11 session, the no-accel config, and the software-GL env"
  say "   then: sudo systemctl restart gdm"
  exit 0
fi

say "=== a16-x11-desktop $(date '+%Y-%m-%d %H:%M:%S')   (log: $LOG) ==="
rule
say "1. install the X server (3 small packages)"
if [ -x /usr/lib/xorg/Xorg ]; then
  say "   already present"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y xserver-xorg-core xserver-xorg-legacy 2>&1 | tail -6 | sed 's/^/   /'
fi

say ""
say "2. tell the X server not to accelerate (nothing may reach msm's render path)"
install -d -m 0755 /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-a16-noaccel.conf <<'EOF'
# A16: written for when the adreno gen8 render path was broken -- gnome-shell's first GPU submit
# oopsed (msm_ioctl_gem_submit) and wedged the machine.  The GPU works on the current kernel;
# this config is kept for the fallback case, and forces the X server not to accelerate.
Section "Device"
    Identifier  "A16 msm"
    Driver      "modesetting"
    Option      "AccelMethod" "none"
EndSection

Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
EOF
say "   wrote /etc/X11/xorg.conf.d/20-a16-noaccel.conf"

say ""
say "3. an X11 session entry for GDM (Ubuntu only ships the Wayland one here)"
if [ -f /usr/share/xsessions/ubuntu-a16-xorg.desktop ]; then say "   already present"; else
install -d -m 0755 /usr/share/xsessions
cat > /usr/share/xsessions/ubuntu-a16-xorg.desktop <<'EOF'
[Desktop Entry]
Name=Ubuntu on Xorg (A16)
Comment=GNOME on X11 with software rendering (fallback; the GPU works on current kernels)
Exec=env GNOME_SHELL_SESSION_MODE=ubuntu gnome-session --session=ubuntu
Type=Application
DesktopNames=GNOME
EOF
say "   wrote /usr/share/xsessions/ubuntu-a16-xorg.desktop"; fi

say ""
say "4. make GDM use X11 instead of Wayland"
[ -f /etc/gdm3/custom.conf.a16.bak ] || cp -a /etc/gdm3/custom.conf /etc/gdm3/custom.conf.a16.bak
python3 - <<'PY'
import re
p='/etc/gdm3/custom.conf'; s=open(p).read()
if re.search(r'(?m)^\s*#?\s*WaylandEnable', s):
    s=re.sub(r'(?m)^\s*#?\s*WaylandEnable.*$','WaylandEnable=false',s)
else:
    s=s.replace('[daemon]','[daemon]\nWaylandEnable=false',1) if '[daemon]' in s else s+'\n[daemon]\nWaylandEnable=false\n'
open(p,'w').write(s); print("   WaylandEnable=false in /etc/gdm3/custom.conf")
PY

say ""
say "5. software GL, so gnome-shell's rendering never opens the GPU"
if [ ! -f /etc/environment.a16-pregl ]; then cp -a /etc/environment /etc/environment.a16-pregl; say "   backup: /etc/environment.a16-pregl"; fi
python3 - <<'PY'
p='/etc/environment'; s=open(p).read()
s=re.sub(r'(?ms)^# A16 software GL.*?^# end A16 software GL\n','',s)
s+= "\n# A16 software GL\nLIBGL_ALWAYS_SOFTWARE=1\nGALLIUM_DRIVER=llvmpipe\n# end A16 software GL\n"
open(p,'w').write(s); print("   set LIBGL_ALWAYS_SOFTWARE=1, GALLIUM_DRIVER=llvmpipe")
PY
rule
say "restarting gdm ... (this is the moment of truth: no GPU is involved any more)"
systemctl restart gdm
sleep 20
say ""
say "gdm             : $(systemctl is-active gdm 2>/dev/null)"
say "graphical.target: $(systemctl is-active graphical.target 2>/dev/null)"
say "gnome-shell     : $(pgrep -c gnome-shell 2>/dev/null || echo 0) process(es)"
say "Xorg            : $(pgrep -c Xorg 2>/dev/null || echo 0) process(es)"
say "session type    : $(loginctl show-session $(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $1}') -p Type --value 2>/dev/null || echo '?')"
rule
say "If the screen is black but the box is alive: Ctrl-Alt-F3 for a console, or reboot into [3]."
say "Reject this with:  sudo bash ~/a16.sh x11 --revert   (then sudo systemctl restart gdm)"
say "Log: $LOG"
