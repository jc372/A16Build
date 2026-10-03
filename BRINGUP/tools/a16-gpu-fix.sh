#!/usr/bin/env bash
# a16-gpu-fix.sh -- one short command, two phases, for fixing the GNOME GPU oops.
#
#   type this at the console:      sudo bash ~/a16.sh
#                                  sudo bash ~/a16.sh daily    (make entry [3] boot to the desktop)
#
# Phase 1 (fix not live yet): installs the rebuilt msm.ko, then tells you to reboot into [3].
# Phase 2 (after that reboot): proves the oopsing ioctl is safe, then starts the desktop.
# It decides which phase it is in by comparing the running module's srcversion with the built one.
#
# Logged to ~/a16-payload/gpu-fix-<timestamp>.log, so if the box wedges and you power-cycle, the
# log survives.  Env overrides for testing: A16_KO_SRC, A16_PROBE, A16_INSTALLER, A16_SKIP_ROOT,
# A16_SKIP_GUI.
set -u
# Sub-mode "daily": strip the test parameters from entry [3] so it boots to the desktop instead of
# a text console (drm.debug=0x1ff and systemd.unit=multi-user.target exist for display debugging).
if [ "${1:-}" = "daily" ]; then
  TOOL=/home/jc/A16Build/BRINGUP/tools/a16-drm-debug-entry.sh
  if [ "$(id -u)" != 0 ]; then
    printf 'This needs root.  Type exactly:  sudo bash ~/a16.sh daily\n'; exit 1
  fi
  echo "=== promoting entry [3] to daily use: removing the test parameters ==="
  echo "-- before:"
  grep -m1 'linux /boot/vmlinuz' /boot/efi/EFI/ubuntu/grub.cfg | tr ' ' '\n' | grep -E 'drm.debug|systemd.unit|consoleblank' | sed 's/^/   /'
  A16_PARAMS="consoleblank=0" bash "$TOOL" remove inline >/dev/null 2>&1
  A16_PARAMS="consoleblank=0" bash "$TOOL" arm | sed 's/^/   /'
  echo "-- after:"
  grep -m1 'linux /boot/vmlinuz' /boot/efi/EFI/ubuntu/grub.cfg | tr ' ' '\n' | grep -E 'drm.debug|systemd.unit|consoleblank' | sed 's/^/   /'
  echo "Entry [3] now boots straight to GDM.  Entry [2] is untouched and stays the fallback."
  exit 0
fi

# Sub-modes: "x11" hands over to the desktop script, so there is still only one file to remember.
if [ "${1:-}" = "x11" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-x11-desktop.sh "$@"
fi

# "display": external outputs (USB-C DP alt-mode / HDMI) -- what the combo PHYs and their clocks do,
# and how to look at a frozen screen.  See BRINGUP/tools/a16-display-outputs.sh.
if [ "${1:-}" = "display" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-display-outputs.sh "$@"
fi

# "dpnext": reversible two-module trial (eDP-only rate override + failed-enable
# guard in MSM, plus the v5 Glymur QMP candidate). Never swaps modules live.
if [ "${1:-}" = "dpnext" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-dp-next.sh "$@"
fi

# "dpdrive": layer a training-time PCS LN0/LN1 drive-level QMP candidate over
# the currently staged dpnext trial; preserves the prior QMP module/initrd.
if [ "${1:-}" = "dpdrive" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-dp-drive.sh "$@"
fi

# "msmlttpr": layer the LTTPR segment-training MSM candidate over the dpnext
# trial; preserves the prior msm.ko and initrd.
if [ "${1:-}" = "msmlttpr" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-msm-lttpr.sh "$@"
fi

# "dprate": layer the external-DP link-rate-cap MSM candidate over the dpnext
# trial; the cap is swept at runtime via /sys/module/msm/parameters/a16_dp_max_rate.
if [ "${1:-}" = "dprate" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-dp-rate.sh "$@"
fi

# "qmpdp": stage or revert the built Glymur QMP combo-PHY candidate; no live reload.
if [ "${1:-}" = "qmpdp" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-qmpdp-module.sh "$@"
fi

# "wifi": the idle/lid-close wedge -- the ath12k firmware stops answering after a resume, and this
# brings the radio back without rebooting.  See BRINGUP/tools/a16-wifi-recover.sh.
if [ "${1:-}" = "wifi" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-wifi-recover.sh "$@"
fi

# "sleep": what a closed lid does, whether a suspend works, and what stops it (docs/suspend.md).
if [ "${1:-}" = "sleep" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-sleep-test.sh "$@"
fi

# "wifisleep": make a suspend stop costing the radio -- s2idle vs deep, the reload-across-suspend
# hook, and the xhci suspend fix (patches/0010; loaded since the 2026-10-02 initramfs rebuild --
# check with  ls /sys/module/xhci_plat_hcd/parameters/  which must show the a16_* knobs).
# See a16-wifi-sleep.sh.
if [ "${1:-}" = "wifisleep" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-wifi-sleep.sh "$@"
fi

# "resume": the lid went down and the machine came back in pieces (panel dark, dock gone, radio
# wedged).  This puts back what can be put back, in one command, and says plainly what cannot --
# the radio's firmware is not recoverable in software.  See a16-resume-recover.sh.
if [ "${1:-}" = "resume" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-resume-recover.sh "$@"
fi

# "ec": the ASUS Zenbook A16 Embedded Controller (fans, temperatures, keyboard backlight, and the
# EC being told about suspend -- the posted 2026-09-17 driver).  See a16-ec.sh.
if [ "${1:-}" = "ec" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-ec.sh "$@"
fi

# "pcielink": stop the PCIe root port from taking the WiFi link down across a suspend.  That is the one
# difference measured between a resume that keeps the radio and one that loses it (2026-09-22):
#   kept it  -- no PCIe lines at all around the resume
#   lost it  -- "pcieport 0004:00:00.0: Recovering Root Port due to Link Down", "ath12k_wifi7_pci
#               0004:01:00.0: AER: can't recover (no error_detected callback)", "Root Port has been
#               reset", "AER: device recovery failed" -- the link dropped, the port re-initialised the
#               device, and ath12k (which implements no PCIe error recovery) never found out.
# pcie_port_pm=off keeps the port from being powered down in the suspend, pcie_aspm=off keeps the link
# out of L1.  Both go into entry [3] (same mechanism as "display arm"), so pick [3] on the next boot.
if [ "${1:-}" = "pcielink" ]; then
  shift
  exec env A16_PARAMS="pcie_port_pm=off pcie_aspm=off" bash /home/jc/A16Build/BRINGUP/tools/a16-drm-debug-entry.sh "$@"
fi

# "radiofix": patches/0014 -- do not SoC-global-reset the WiFi device on resume (the Wi-Fi wedge).
if [ "${1:-}" = "radiofix" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-install-ath12k-resume-fix.sh "$@"
fi

# "kdump": arm the crash kernel so the next panic leaves a backtrace.  The machine panics on some
# resume attempts (the EC indicator LEDs flash -- CONFIG_LEDS_TRIGGER_PANIC lights every LED on a
# panic -- and with panic=0 it then just sits there).  A panic mid-suspend leaves nothing in the
# journal and nothing in efi_pstore (the runtime services are down at that point), but the cmdline
# already reserves a crash kernel, so a dump is possible once it is loaded.  See a16-arm-kdump.sh.
if [ "${1:-}" = "kdump" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-arm-kdump.sh "$@"
fi

# "commands": put the two console commands (reload_wifi, lid_sleep) where the shell finds them.
if [ "${1:-}" = "commands" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-install-console-commands.sh "$@"
fi

# "suspendfix": install/revert the patched xhci-plat-hcd.ko (why the lid's second suspend aborts).
if [ "${1:-}" = "suspendfix" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-install-xhci-suspend-fix.sh "$@"
fi

# "default": which menu entry the machine boots unattended (standing choice: [3]).
if [ "${1:-}" = "default" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-set-default-entry.sh "$@"
fi

# "phyclock": why the tert combo PHY's clock bundle is refused (read-only, then an opt-in cycle).
if [ "${1:-}" = "phyclock" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-phy-clock-test.sh "$@"
fi

# "tertphy": test whether the tert PHY's COM block is simply unpowered (DTB edit, reboot, revert).
# "grub": prune the ESP boot menu (drops [0] [1] [4] and both [8]s, keeps [2] the failsafe and [3]
# the one in use, adds [9] command-line-only) -- plan first, then apply.  Backs up + grub-script-checks.
if [ "${1:-}" = "grub" ]; then
  shift
  exec bash "$(dirname "$(readlink -f "$0")")/a16-grub-menu.sh" "$@"
fi

# "apps": remember which apps are open and reopen them at the next login (no root needed).
#   bash ~/a16.sh apps install | list | save | restore | status | uninstall
if [ "${1:-}" = "apps" ]; then
  shift
  exec bash "$(dirname "$(readlink -f "$0")")/a16-session-apps.sh" "$@"
fi

# "gdmfix": permanently stop the seat-less user manager from starting before the greeter.
# Disables logind lingering for jc; effective on the next full boot. Does not restart GDM or kill
# the current desktop. The Hermes Gateway then starts at the first jc login, not before login.
if [ "${1:-}" = "gdmfix" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-gdm-session-fix.sh "$@"
fi

# "power": the machine's power/lid policy.  Lid closed = poweroff, power button = poweroff -- the
# strategy chosen 2026-10-03: a power cycle replaces suspend on a machine that boots in under 20 s.
#   sudo bash ~/a16.sh power apply | status | revert
# "login": one-line recovery for a black screen / failed graphical login (the session-manager trap):
# ends the seat-less jc sessions, restarts the greeter, activates its session, puts the panel on its VT.
if [ "${1:-}" = "power" ] || [ "${1:-}" = "login" ]; then
  _m="$1"; shift
  _d=$(dirname "$(readlink -f "$0")")
  [ "$_m" = "login" ] && set -- login "$@"
  exec bash "$_d/a16-power-policy.sh" "$@"
fi

if [ "${1:-}" = "tertphy" ]; then
  shift
  exec bash /home/jc/A16Build/BRINGUP/tools/a16-tert-phy-power.sh "$@"
fi

KVER=$(uname -r)
KO_SRC=${A16_KO_SRC:-/home/jc/build/linux-next-1a1de54f7369/drivers/gpu/drm/msm/msm.ko}
INSTALLER=${A16_INSTALLER:-/home/jc/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh}
PROBE=${A16_PROBE:-/home/jc/A16Build/BRINGUP/tools/a16-gpu-param-probe.py}
SKIP_ROOT=${A16_SKIP_ROOT:-0}
SKIP_GUI=${A16_SKIP_GUI:-0}
UPD=/lib/modules/$KVER/updates/a16
LOG=/home/jc/a16-payload/gpu-fix-$(date +%Y%m%d-%H%M%S).log
mkdir -p /home/jc/a16-payload 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

say(){ printf '%s\n' "$*"; }
rule(){ say "----------------------------------------------------------------"; }

# The kernel's own offset for a field, from its BTF; then the same field in a module's DWARF.
# A mismatch means the module was built against a different config -- see a16-fix-build-config.sh.
kernel_off(){ bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>/dev/null | python3 -c "
import sys,re
want='$1'; lines=sys.stdin.read().split('\n')
for i,l in enumerate(lines):
    if re.match(r\"\[\d+\] STRUCT 'task_struct' \", l) and 'size=' in l:
        for m in lines[i+1:]:
            if not m.startswith('\t'): break
            g=re.match(r\"\t'(\\w+)' type_id=\\d+ bits_offset=(\\d+)\", m)
            if g and g.group(1)==want: print(int(g.group(2))//8); sys.exit()
"; }
a16_abi_check(){ # $1 = module file
  local k o
  k=$(kernel_off thread_pid); o=$(gdb -batch -ex 'ptype /o struct task_struct' "$1" 2>/dev/null | awk '/thread_pid;/{print $2; exit}')
  if [ -z "$o" ]; then echo "thread_pid: kernel=$k module=<no debug info to check>"; return; fi
  if [ "$o" = "$k" ]; then echo "thread_pid offset kernel=$k module=$o  OK"
  else echo "thread_pid offset kernel=$k module=$o  MISMATCH -- rebuild with a16-fix-build-config.sh"; fi
}

say "=== a16-gpu-fix $(date '+%Y-%m-%d %H:%M:%S')   kernel $KVER ==="
say "log             : $LOG"
say "running msm     : $(cat /sys/module/msm/srcversion 2>/dev/null || echo '(msm not loaded)')"
say "built msm.ko    : $(stat -c %s "$KO_SRC" 2>/dev/null || echo 0) bytes, sha256 $(sha256sum "$KO_SRC" 2>/dev/null | cut -c1-16)"
say "installed .ko   : $(sha256sum "$UPD/msm.ko" 2>/dev/null | cut -c1-16 || echo '(none)')"
rule

if [ "$SKIP_ROOT" != 1 ] && [ "$(id -u)" != 0 ]; then
  say "This needs root. Type exactly this line:"
  say ""
  say "    sudo bash ~/a16.sh"
  say ""
  exit 1
fi

built=$(sha256sum "$KO_SRC" 2>/dev/null | awk '{print $1}')
running=$(sha256sum "$UPD/msm.ko" 2>/dev/null | awk '{print $1}')

# ----------------------------------------------------------------- phase 1: install
if [ "$running" != "$built" ] || [ -z "$built" ]; then
  say "PHASE 1 -- the fixed msm is not the running one. Installing it now."
  say ""
  if [ ! -f "$KO_SRC" ]; then say "FATAL: $KO_SRC is missing. Nothing changed."; exit 1; fi
  bash "$INSTALLER" "$KO_SRC"
  # do not trust the installer's exit alone: check the destination really is this build
  installed_now=$(modinfo -F srcversion "$UPD/msm.ko" 2>/dev/null || echo none)
  say ""
  if [ "$(sha256sum "$UPD/msm.ko" 2>/dev/null | awk '{print $1}')" = "$built" ]; then
    say "VERIFIED  : $UPD/msm.ko is byte-identical to $KO_SRC"
    say "resolves  : $(modinfo -F filename msm 2>/dev/null)"
    say "ABI check : $(a16_abi_check "$UPD/msm.ko")"
  else
    say "NOT INSTALLED: $UPD/msm.ko is $(modinfo -F srcversion "$UPD/msm.ko" 2>/dev/null || echo 'absent'), wanted $built"
    say "Fix that before rebooting -- the install above did not take effect."
    exit 1
  fi
  rule
  say "NEXT STEP -- reboot into entry [3], then run the same short command again:"
  say ""
  say "    1.  sudo reboot"
  say "    2.  (pick [3] in the menu if it is not already the default)"
  say "    3.  at the console:   sudo bash ~/a16.sh"
  say ""
  say "That second run takes one second to test the ioctl that used to oops the kernel, and starts"
  say "the desktop only if it is safe."
  exit 0
fi

# ----------------------------------------------------------------- phase 2: prove + start
say "PHASE 2 -- the running msm is the build in the tree."
say ""
say "-- test 0: does the loaded module's ABI match the running kernel? (this is what was wrong)"
abi=$(a16_abi_check "$UPD/msm.ko")
say "   $abi"
if printf '%s' "$abi" | grep -q MISMATCH; then
  say ""
  say "STOPPING: the installed msm.ko was built with a config that disagrees with the kernel,"
  say "so its struct offsets are wrong and it will oops.  Rebuild first:"
  say "   bash /home/jc/A16Build/BRINGUP/tools/a16-fix-build-config.sh"
  say "   make -C /home/jc/build/linux-next-1a1de54f7369 ARCH=arm64 M=drivers/gpu/drm/msm clean"
  say "   make -C /home/jc/build/linux-next-1a1de54f7369 ARCH=arm64 M=drivers/gpu/drm/msm msm.ko"
  say "then run this script again."
  exit 1
fi
say ""
say "-- test 1: the ioctl gnome-shell uses, which used to oops the kernel"
probe_out=$(python3 "$PROBE" 2>&1); probe_rc=$?
printf '%s\n' "$probe_out"
rule
if ! printf '%s' "$probe_out" | grep -q 'survived: no oops'; then
  say "TEST 1 FAILED (exit $probe_rc) -- NOT starting the desktop. Nothing was changed."
  say "  ENOTTY  in the output above = the ioctl number is wrong (tell me)."
  say "  an oops  in the output above = the fix is not in the running module."
  exit 1
fi
say "-- test 2: the display link the desktop will re-mode"
say "   card1-eDP-1 : $(cat /sys/class/drm/card1-eDP-1/status 2>/dev/null || echo '?') / $(cat /sys/class/drm/card1-eDP-1/enabled 2>/dev/null || echo '?')"
say "   modes       : $(cat /sys/class/drm/card1-eDP-1/modes 2>/dev/null | tr '\n' ' ')"
say "   backlight   : $(ls /sys/class/backlight/ 2>/dev/null | tr '\n' ' ') $(cat /sys/class/backlight/*/brightness 2>/dev/null)/$(cat /sys/class/backlight/*/max_brightness 2>/dev/null)"
rule
say "Both tests passed."

if [ "$SKIP_GUI" = 1 ]; then
  say "(A16_SKIP_GUI=1: not starting the desktop -- this was a dry run.)"
  exit 0
fi

say "Starting the desktop in 5 seconds -- press Ctrl-C now to stay at the console."
for i in 5 4 3 2 1; do printf '\r   starting graphical.target in %s ... ' "$i"; sleep 1; done
say ""
say "starting: systemctl isolate graphical.target"
systemctl isolate graphical.target
say ""
say "graphical.target : $(systemctl is-active graphical.target)"
say "gdm              : $(systemctl is-active gdm 2>/dev/null)"
say "gnome-shell procs: $(pgrep -c gnome-shell 2>/dev/null || echo 0)"
rule
say "Black screen again but the machine is alive? Ctrl-Alt-F3, or reboot into [3]."
say "This run's log: $LOG"
