#!/usr/bin/env bash
# a16-display-outputs.sh -- what the three external display outputs and the QMP combo PHYs are doing.
#
#   type this:            sudo bash ~/a16.sh display           # one dump; nothing has to be plugged in
#                         sudo bash ~/a16.sh display watch     # monitor connectors + stream kernel messages to the log
#                         sudo bash ~/a16.sh display watch dp  # short DP-only kernel debug during a risky hotplug
#                         sudo bash ~/a16.sh display arm       # shrink drm.debug to 0x1fe on the debug entry
#                         sudo bash ~/a16.sh display recover   # after a frozen screen: restart gdm (needs the
#                                                              #   monitor unplugged)
#                         sudo bash ~/a16.sh display evict     # a frozen desktop and you CAN still SSH: force
#                                                              #   the wedged external output off, which is
#                                                              #   the software equivalent of unplugging it,
#                                                              #   then 'recover'
#                         sudo bash ~/a16.sh display wake      # after a resume left the built-in panel dark
#                                                              #   while SSH still works: turn the backlight
#                                                              #   back on and show the output's state
#                         sudo bash ~/a16.sh display hook      # install a resume hook that does the above by
#                                                              #   itself, and only when the panel is really
#                                                              #   dark (it restarts gdm;  'hook remove' undoes it)
#
# Why the dump looks like this: plugging an external display does not merely fail, it freezes the
# desktop.  Both halves of the failure are visible on this machine:
#
#   * the QMP combo PHY cannot enable its own clocks --
#         gcc_usb3_tert_phy_com_aux_clk status stuck at 'off'   (clk-branch.c:87 WARN, -EBUSY)
#         Failed to enable clk 'com_aux': -16
#         phy phy-88e1000.phy.12: phy init failed --> -16
#     raised from qmp_combo_com_init -> phy_init -> msm_dp_ctrl_phy_init, i.e. the HDMI output's PHY.
#     It happened at every boot, with nothing plugged in (the fbdev client probes the HDMI bridge).
#     ROOT CAUSE FOUND 2026-09-17: the PHY's controller domain `gcc_usb30_tert_gdsc` was never
#     powered (its only DT consumer is a disabled USB controller that defers on this PHY itself).
#     `tools/a16-tert-phy-power.sh` (`sudo bash ~/a16.sh tertphy arm bridge`) puts the domain on a
#     consumer that binds, and the failure goes away -- this dump would show it again if that
#     regresses, or on the USB-C DP side, which has not been re-tested.
#   * the DP controller then has no link clock (its parent is the PHY's DP link clock):
#         disp_cc_mdss_dptx1_link_clk status stuck at 'off'
#         *ERROR* Unable to start link clocks. ret=-16 / DP display prepare failed, rc=-16
#     and the atomic commit that was bringing the output up never completes:
#         [dpu error]vblank timeout / [dpu error]wait for commit done returned -110
#         [dpu error]enc38 frame done timeout
#     after which the compositor's KMS thread spins in DRM_IOCTL_WAIT_VBLANK forever: the picture is
#     frozen but the kernel is alive (logind still answers the power key), so this is reachable over
#     SSH and does not need a power cycle.
#
# So this script prints the state that decides which of the two is happening: are the PHY's clock
# branches actually running (clk_summary + per-clock counts), is the PHY's power domain on
# (pm_genpd_summary), and what does the kernel say about the outputs.
#
# Logged to ~/a16-payload/display-outputs-<timestamp>.log so it survives a power cycle.
# Env overrides for testing: A16_SKIP_ROOT, A16_LOG, A16_DRY.
set -u

MODE="${1:-dump}"
ARG="${2:-}"
LOG="${A16_LOG:-/home/jc/a16-payload/display-outputs-$(date +%Y%m%d-%H%M%S).log}"
DEBUG_ENTRY=/home/jc/A16Build/BRINGUP/tools/a16-drm-debug-entry.sh
DRMPARAM=/sys/module/drm/parameters/debug

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }

# Every clock that any of this depends on: the three combo PHYs' aux/com_aux, the dispcc DPTX
# link/pixel/AUX clocks, the tcsr clockrefs, and the GCC USB PHY gates.
CLK_RE='dptx[0-3]_(link|pixel|aux|link_intf)|usb3_(prim|sec|tert|mp)_phy|usb_[0-2]_phy|clkref|GCC_USB3_(PRIM|SEC|TERT)|_phy_aux_clk|edp[0-3]'
GDSC_RE='usb.*phy|usb3|disp_cc_mdss'

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

case "$MODE" in
  arm)
    # 0x1ff turns on every DRM category, including DRM_UT_CORE, whose ioctl logging wrote 7.6 million
    # lines in 90 minutes on the last debug boot -- journald then dropped kernel messages ("Missed 20
    # kernel messages") and the pre-freeze record was lost.  0x1fe keeps KMS/ATOMIC/VBL/DP and drops
    # just DRM_UT_CORE, which is the ioctl spam.
    if [ "$(id -u)" != 0 ]; then say "This needs root.  Type exactly:  sudo bash ~/a16.sh display arm"; exit 1; fi
    A16_PARAMS="consoleblank=0 drm.debug=0x1fe" bash "$DEBUG_ENTRY" remove inline >/dev/null 2>&1
    A16_PARAMS="consoleblank=0 drm.debug=0x1fe" bash "$DEBUG_ENTRY" arm | sed 's/^/   /'
    say ""
    say "Entry [3] now carries drm.debug=0x1fe.  Reboot, pick [3], plug the monitor, then:"
    say "    sudo bash ~/a16.sh display"
    exit 0
    ;;
  wake)
    # After a resume the desktop can be alive and reachable over SSH with a dark panel.  Two different
    # states look identical from in front of the machine, so both are checked here:
    #   * the panel backlight was powered down -- the built-in panel uses dp_aux_backlight, and bl_power
    #     reads 4 (FB_BLANK_POWERDOWN) after some resumes while brightness itself is unchanged
    #   * the output is off altogether -- card1-eDP-1 reports enabled=disabled
    # Measured 2026-09-22 11:56 after the first resume that kept the radio: bl_power=4, brightness=628/2047,
    # card1-eDP-1 status=connected enabled=disabled, gnome-shell running, SSH fine.
    if [ "$(id -u)" != 0 ]; then say "This needs root.  Type exactly:  sudo bash ~/a16.sh display wake"; exit 1; fi
    rule
    say "-- backlight"
    for b in /sys/class/backlight/*; do
      [ -e "$b/brightness" ] || continue
      say "   $(basename "$b"): brightness=$(cat "$b/brightness" 2>/dev/null)/$(cat "$b/max_brightness" 2>/dev/null)  bl_power=$(cat "$b/bl_power" 2>/dev/null)   (4 = powered down)"
      if [ "$(cat "$b/bl_power" 2>/dev/null)" != "0" ]; then
        say "   turning it back on (echo 0 > $b/bl_power)"
        if echo 0 > "$b/bl_power" 2>/dev/null; then say "   done -- if the panel lights up, that was all it needed"
        else say "   could not write it (the panel may need the compositor to redo the modeset instead)"; fi
      fi
    done
    say "-- built-in panel output"
    for c in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-DSI-*; do
      [ -e "$c/status" ] || continue
      say "   $(basename "$c"): status=$(cat "$c/status" 2>/dev/null) enabled=$(cat "$c/enabled" 2>/dev/null)"
    done
    say "-- still dark?  restart the session's compositor, which sets the mode again:"
    say "      sudo systemctl restart gdm          (SSH and the radio are not affected)"
    say "-- and if that does not either: the picture is frozen/off at the display pipeline level, which is"
    say "   the separate black-screen thread -- see BRINGUP/notes/ for the DPU/vblank work."
    exit 0
    ;;
  hook)
    # The panel came back dark after the first keep-MHI resume and 'sudo systemctl restart gdm' fixed it
    # (the backlight alone was not enough -- the output itself was left disabled, so the compositor has
    # to set the mode again).  This installs that nudge as a system-sleep hook, guarded so a resume that
    # brings the display back normally does not cost the session.
    if [ "$(id -u)" != 0 ]; then say "This needs root.  Type exactly:  sudo bash ~/a16.sh display hook"; exit 1; fi
    HOOK=/usr/lib/systemd/system-sleep/a16-display-wake
    CONF=/etc/a16-display-wake.conf
    case "$ARG" in
      remove)
        rm -f "$HOOK" "$CONF" && say "-- removed $HOOK (and $CONF)"
        say "   the next resume will leave the panel dark again if it happens (use 'display wake')"
        exit 0 ;;
      always|always-on)
        # A16: the aggressive mode is a landmine -- "always" makes the hook cycle the VT and poke the
        # live session bus on EVERY resume, dark panel or not, and the session-bus call is the same
        # reach-into-the-user-session pattern that leaves an orphan user manager and breaks the
        # graphical login (see notes/2026-10-03-session-manager-trap.md).  Require an explicit
        # acknowledgement so a future session cannot re-arm it by accident.
        if [ "${A16_I_KNOW:-0}" != 1 ]; then
          say "REFUSING 'hook always': it pokes your live session on every resume, which is the pattern"
          say "   that leaves an orphan user manager and breaks the graphical login -- see"
          say "   notes/2026-10-03-session-manager-trap.md."
          say "   If you really want it:  A16_I_KNOW=1 sudo bash ~/a16.sh display hook always"
          exit 1
        fi
        printf 'A16_ALWAYS=1\n' > "$CONF"
        say "-- $CONF: A16_ALWAYS=1   (A16_I_KNOW was set -- you asked for this)"
        say "   the hook will cycle the VT after EVERY resume, before it checks anything: two seconds of"
        say "   console.  Use it if the panel sometimes reports itself enabled while showing nothing --"
        say "   the dark test cannot see that case.  'hook conditional' puts it back." ;;
      conditional|always-off)
        rm -f "$CONF"
        say "-- $CONF removed: the hook acts only when the panel actually reads as dark" ;;
      status)
        if [ -f "$HOOK" ]; then say "-- installed: $HOOK"; else say "-- not installed"; fi
        if [ -f "$CONF" ]; then say "-- $(tr '\n' ' ' < "$CONF")   (VT cycle after every resume)"
        else say "-- conditional mode: cycle the VT only when the panel reads as dark"; fi
        exit 0 ;;
    esac
    say "-- writing $HOOK"
    cat > "$HOOK" <<'HOOKEOF'
#!/bin/bash
# A16: after a resume the built-in panel can be left dark -- dp_aux_backlight bl_power=4 and
# card*-eDP-* enabled=disabled -- while the machine, the session and SSH are all fine.  Writing
# bl_power=0 alone does not bring the picture back: the output has to be enabled again, which the
# compositor does when it sets the mode.  So: if the panel is STILL dark after a resume, restart gdm
# once.  It is checked twice -- five seconds after the resume and again seven seconds later -- so a
# resume that is merely slow, or a panel that takes a moment, does not cost you your session.
# Nothing here runs when the display came back on its own.
case "${1:-}" in post) ;; *) exit 0 ;; esac

panel_dark() {
  bl=$(cat /sys/class/backlight/*/bl_power 2>/dev/null | head -1)
  en=$(cat /sys/class/drm/card*-eDP-*/enabled 2>/dev/null | head -1)
  [ "${bl:-0}" != "0" ] || [ "${en:-enabled}" != "enabled" ]
}

# Cycle the VT away and back -- the operator's own workaround (ctrl-alt-f3, then ctrl-alt-f2).  The VT
# switch deactivates and reactivates the DRM session, and the compositor does a full modeset on the way
# back (measured 2026-10-02 21:59:10: 'dpu_crtc_commit_kickoff crtc110 first commit' as the session was
# re-activated), which re-enables an output the resume left disabled.  The session is not lost -- it is
# backgrounded for two seconds.
vt_cycle() {
  local cur other
  command -v chvt >/dev/null 2>&1 || return 1
  cur=$(cat /sys/class/tty/tty0/active 2>/dev/null | sed 's/tty//')
  [ -n "$cur" ] || return 1
  other=$([ "$cur" = "3" ] && echo 2 || echo 3)
  chvt "$other" 2>/dev/null || return 1
  sleep 2
  chvt "$cur" 2>/dev/null || return 1
  sleep 2
}

[ -r /etc/a16-display-wake.conf ] && . /etc/a16-display-wake.conf

sleep 5
if [ "${A16_ALWAYS:-0}" = 1 ]; then
  logger -t a16-display-wake "always mode: cycling the VT after the resume"
  vt_cycle
fi
panel_dark || exit 0          # the panel came back by itself
sleep 7
panel_dark || exit 0          # slow, but it did come back
bl=$(cat /sys/class/backlight/*/bl_power 2>/dev/null | head -1)
en=$(cat /sys/class/drm/card*-eDP-*/enabled 2>/dev/null | head -1)
if [ "${bl:-0}" = "0" ] && [ "${en:-enabled}" = "enabled" ]; then
	exit 0
fi
# --- rung 0: the VT cycle (keeps the session; this is the operator's own workaround) ----------
logger -t a16-display-wake "panel dark after the resume (bl_power=${bl:-?} eDP=${en:-?}): cycling the VT"
if vt_cycle && ! panel_dark; then
  logger -t a16-display-wake "the VT cycle brought the panel back -- session kept"
  exit 0
fi

# --- rung 1: (deliberately removed) do NOT reach into the user session -------------------------
# This rung used to ask mutter to leave power-save over the user's session bus:
#     runuser -u jc -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=... busctl --user
#         set-property ... PowerSaveMode i 0
# That is the reach-into-the-session-from-root pattern that leaves an orphan user manager and makes
# the graphical login die (org.gnome.Shell@ubuntu.service fails, gdm-authd ServiceUnavailable,
# grey -> black) -- see notes/2026-10-03-session-manager-trap.md, rule 2.  The VT cycle above is the
# operator's own workaround and never touches the session bus; if it did not bring the panel back,
# the honest next step is the greeter restart below, not a poke at a session we cannot verify.
echo 0 > /sys/class/backlight/*/bl_power 2>/dev/null   # unblank: sysfs only, no session involved
sleep 4
if ! panel_dark; then
  logger -t a16-display-wake "the backlight write brought the panel back -- session kept"
  exit 0
fi

# --- rung 2: restart gdm (guaranteed picture; costs the session) ------------------------------
logger -t a16-display-wake "still dark after the session nudge (PowerSaveMode was ${PSM:-?}); restarting gdm"
echo 0 > /sys/class/backlight/*/bl_power 2>/dev/null
# detached, so this hook can exit while the restart happens
systemd-run --on-active=3 --unit=a16-display-wake --collect systemctl restart gdm \
	|| (setsid nohup bash -c 'sleep 3; systemctl restart gdm' >/dev/null 2>&1 &)
exit 0
HOOKEOF
    chmod 755 "$HOOK"
    say "   installed: $HOOK   (mode 755)"
    say ""
    say "   what it does on a resume: only if the panel is dark (bl_power != 0 or the eDP output is not"
    say "   enabled) it turns the backlight on and restarts gdm ~3 s later, which re-sets the mode."
    say "   A resume where the display is fine is left alone -- your session survives it."
    say ""
    say "   the cost of the restart: a fresh login screen (the session is logged out), because the mode"
    say "   can only be re-set by a compositor that starts from scratch."
    say "   remove it with:  sudo bash ~/a16.sh display hook remove"
    exit 0 ;;
  recover)
    if [ "$(id -u)" != 0 ]; then say "This needs root.  Type exactly:  sudo bash ~/a16.sh display recover"; exit 1; fi
    bad=""
    for c in /sys/class/drm/card*-DP-1 /sys/class/drm/card*-DP-2 /sys/class/drm/card*-HDMI-A-1; do
      [ -e "$c/status" ] || continue
      s=$(cat "$c/status" 2>/dev/null)
      case "$s" in connected) bad="$bad $(basename "$c")";; esac
    done
    if [ -n "$bad" ]; then
      say "Refusing to restart the display manager while an external output is still connected:$bad"
      say "Unplug the monitor first -- re-running a modeset onto the output that wedged the commit"
      say "would most likely wedge it again."
      say ""
      say "If you cannot unplug it (or are on SSH), take it out of the compositor's view instead:"
      say "    sudo bash ~/a16.sh display evict"
      say "then run this again."
      exit 1
    fi
    say "No external output connected.  Restarting gdm to rebuild the desktop..."
    systemctl restart gdm && say "gdm restarted." || say "gdm restart failed."
    exit 0 ;;
  evict)
    # The freeze this exists for (2026-10-02 20:53:54, boot d92a3795): an external DP output fails link
    # training, so its DPU interface never gets a pixel clock.  patches/0020 drops the stuck flush, but
    # every later atomic commit still CONTAINS that dead output, so each one times out again -- 41
    # 'wait for commit done' / 'vblank timeout' lines -- and the desktop stops updating while the kernel,
    # SSH and the network stay alive.  Unplugging the monitor is what clears it (the compositor then
    # rebuilds without it).  This does the same thing in software: force the connector off so DRM
    # reports it disconnected and the compositor drops it.
    if [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-0}" != 1 ]; then
      say "This needs root.  Type exactly:  sudo bash ~/a16.sh display evict"
      exit 1
    fi
    bad=""
    for c in /sys/class/drm/card*-DP-1 /sys/class/drm/card*-DP-2 /sys/class/drm/card*-HDMI-A-1; do
      [ -e "$c/status" ] || continue
      case "$(cat "$c/status" 2>/dev/null)" in connected) bad="$bad $c";; esac
    done
    if [ -z "$bad" ]; then
      say "-- no external output is connected: nothing to evict"
      say "   (if the desktop is still frozen, the dead output is already out of the way -- try"
      say "    'sudo bash ~/a16.sh display recover')"
      exit 0
    fi
    say "-- present state:"
    for c in $bad; do
      say "   $(basename "$c")  status=$(cat "$c/status" 2>/dev/null)  enabled=$(cat "$c/enabled" 2>/dev/null)  mode=$(cat "$c/modes" 2>/dev/null | head -1)"
    done
    say ""
    say "-- forcing these off (the software equivalent of unplugging them):"
    for c in $bad; do
      printf 'off' > "$c/status" 2>/dev/null || say "   $(basename "$c"): write to status FAILED"
      sleep 1
      say "   $(basename "$c")  status=$(cat "$c/status" 2>/dev/null)  enabled=$(cat "$c/enabled" 2>/dev/null)"
    done
    say ""
    say "   what to do next:"
    say "     1. if the desktop is still frozen, rebuild it:  sudo bash ~/a16.sh display recover"
    say "        (it can proceed now: nothing reports as connected)"
    say "     2. unplugging and replugging the monitor restores normal detection by itself; if you want"
    say "        detection back without a replug:  echo detect | sudo tee /sys/class/drm/card<N>-<conn>/status"
    say ""
    say "   this does not fix the link training failure -- it stops that failure from taking the desktop"
    say "   with it.  See BRINGUP/evidence/2026-10-02-dp2-attach-froze-desktop-ssh-alive.txt."
    exit 0 ;;
    esac

if [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-0}" != 1 ]; then
  say "This needs root. Type exactly this line:"
  say ""
  say "    sudo bash ~/a16.sh display"
  say ""
  exit 1
fi

# ---------------------------------------------------------------- one dump
snapshot() {
  local now; now=$(date '+%Y-%m-%d %H:%M:%S')
  say "=== a16-display-outputs  $now ==="
  say "kernel        : $(uname -r)"
  say "boot id       : $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  say "drm.debug     : $(cat $DRMPARAM 2>/dev/null || echo '?')  (0x1ff includes DRM_UT_CORE = ioctl spam)"
  say "cmdline       : $(tr -s ' ' < /proc/cmdline)"
  rule

  say "-- connectors"
  for c in /sys/class/drm/card*-*; do
    [ -e "$c/status" ] || continue
    printf '   %-14s status=%-12s enabled=%-3s modes=%s\n' "$(basename "$c")" \
      "$(cat "$c/status" 2>/dev/null)" "$(cat "$c/enabled" 2>/dev/null)" \
      "$(tr '\n' ' ' < "$c/modes" 2>/dev/null | cut -c1-40)"
  done

  say "-- which PHY feeds which DP controller (from the machine's DT)"
  python3 - <<'PY' 2>/dev/null || say "   (DT walk unavailable)"
import os, struct
root = '/proc/device-tree'
def rd(p):
    try: return open(p, 'rb').read()
    except Exception: return None
def u32(b): return struct.unpack('>' + 'I' * (len(b) // 4), b[:len(b) // 4 * 4])
ph = {}
for dp_, dirs, files in os.walk(root):
    if 'phandle' in files:
        v = rd(os.path.join(dp_, 'phandle'))
        if v: ph[u32(v)[0]] = dp_.replace(root, '')
for dp_, dirs, files in os.walk(root):
    if os.path.basename(dp_).startswith('displayport-controller@'):
        props = {f: rd(os.path.join(dp_, f)) for f in files}
        reg = u32(props.get('reg', b''))
        acp = u32(props.get('assigned-clock-parents', b''))
        clk = u32(props.get('clocks', b''))
        phys = u32(props.get('phys', b''))
        st = (props.get('status', b'?').rstrip(b'\x00') or b'?').decode(errors='replace')
        print('   %-16s status=%-9s phy=%s  link-clock-parent=%s' % (
            'dp@%x' % reg[1], st,
            ph.get(phys[0], '?') if len(phys) else '?',
            ph.get(acp[0], '?') if len(acp) else '?'))
PY

  say "-- combo PHYs: driver, runtime PM, suppliers"
  for p in /sys/bus/platform/devices/*.phy; do
    [ -e "$p" ] || continue
    drv=$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null)
    case "$drv" in *combo*|*edp*) ;; *) continue;; esac
    printf '   %-14s driver=%-20s runtime=%-10s%s\n' "$(basename "$p")" "$drv" \
      "$(cat "$p/power/runtime_status" 2>/dev/null)" \
      "$(grep -c . < <(ls "$p" 2>/dev/null | grep '^supplier:') | sed 's/^/  suppliers=/')"
    for s in "$p"/supplier:*; do
      [ -e "$s" ] && say "      supplier: $(basename "$s")"
    done
  done

  say "-- clock tree (clk_summary, matching lines with their children)"
  if [ -r /sys/kernel/debug/clk/clk_summary ]; then
    grep -E "$CLK_RE" /sys/kernel/debug/clk/clk_summary | sed 's/^/   /' | head -80
  else
    say "   (clk_summary not readable)"
  fi

  say "-- the decisive clocks, per-clock counters"
  for c in gcc_usb3_tert_phy_com_aux_clk gcc_usb3_tert_phy_aux_clk gcc_usb3_sec_phy_com_aux_clk \
           gcc_usb3_prim_phy_com_aux_clk; do
    [ -e "/sys/kernel/debug/clk/$c" ] || continue
    printf '   %-34s parent=%-30s rate=%-12s enable=%s prepare=%s\n' "$c" \
      "$(cat "/sys/kernel/debug/clk/$c/clk_parent" 2>/dev/null | awk '{print $NF}')" \
      "$(cat "/sys/kernel/debug/clk/$c/clk_rate" 2>/dev/null)" \
      "$(cat "/sys/kernel/debug/clk/$c/clk_enable_count" 2>/dev/null)" \
      "$(cat "/sys/kernel/debug/clk/$c/clk_prepare_count" 2>/dev/null)"
  done

  say "-- power domains (pm_genpd_summary, matching lines)"
  if [ -r /sys/kernel/debug/pm_genpd/pm_genpd_summary ]; then
    grep -E "$GDSC_RE|domain" /sys/kernel/debug/pm_genpd/pm_genpd_summary | sed 's/^/   /' | head -40
  else
    say "   (pm_genpd_summary not readable)"
  fi

  for b in 0 -1; do
    if [ "$b" = 0 ]; then say "-- this boot: the external-display failures the kernel has logged"
    else say "-- previous boot (the one that froze, if that is what happened)"; fi
    journalctl -k -b "$b" --no-pager -o short-precise 2>/dev/null \
      | grep -E "stuck at 'o|Failed to enable clk|phy init failed|phy_power_on was called|Unable to start link clocks|DP display prepare failed|Failed link training|\[dpu error\]|com_aux|dptx" \
      | grep -v -E 'Modules linked in|Tainted:|Call trace|drm_dp_dpcd|AUX ->' \
      | tail -30 | sed 's/^/   /'
  done
  rule
}

if [ "$MODE" = watch ]; then
  case "$ARG" in
    ''|dp) ;;
    *) say "usage: sudo bash ~/a16.sh display watch [dp]"; exit 2 ;;
  esac
  WATCH_DRM_DEBUG_BEFORE=""
  say "Watching connector state and a separate live kernel log. Hotplug may hang or reboot the machine. Ctrl-C stops the watcher."
  say "Connector/state log: $LOG"
  KERNEL_LOG="${A16_KERNEL_LOG:-${LOG%.log}.kernel.log}"
  say "Live kernel log: $KERNEL_LOG"
  : >> "$KERNEL_LOG" 2>/dev/null || {
    say "ERROR: cannot write kernel log: $KERNEL_LOG"
    exit 1
  }
  if [ "$ARG" = dp ]; then
    WATCH_DRM_DEBUG_BEFORE="$(cat "$DRMPARAM" 2>/dev/null)"
    if [ -z "$WATCH_DRM_DEBUG_BEFORE" ] || ! printf '0x100\n' > "$DRMPARAM"; then
      say 'ERROR: could not enable temporary DP-only DRM debug; no hotplug capture started.'
      exit 1
    fi
    trap 'printf "%s\n" "$WATCH_DRM_DEBUG_BEFORE" > "$DRMPARAM"' EXIT
    say "DRM DP-only debug enabled temporarily (previous=$WATCH_DRM_DEBUG_BEFORE, now=0x100; no ioctl spam)."
  fi
  printf '\n=== live kernel stream start %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$KERNEL_LOG"
  sync "$KERNEL_LOG" 2>/dev/null || true

  WATCH_KMSG_PID=""
  WATCH_SYNC_PID=""
  WATCH_KMSG_SOURCE=""
  if command -v dmesg >/dev/null 2>&1; then
    WATCH_KMSG_SOURCE="dmesg --follow-new --time-format=raw"
    if command -v stdbuf >/dev/null 2>&1; then
      (exec stdbuf -oL dmesg --follow-new --time-format=raw) >> "$KERNEL_LOG" 2>&1 &
    else
      (exec dmesg --follow-new --time-format=raw) >> "$KERNEL_LOG" 2>&1 &
    fi
    WATCH_KMSG_PID=$!
  elif command -v journalctl >/dev/null 2>&1; then
    WATCH_KMSG_SOURCE="journalctl -k --follow (short-monotonic)"
    if command -v stdbuf >/dev/null 2>&1; then
      (exec stdbuf -oL journalctl -k --follow -n 0 --no-pager -o short-monotonic) >> "$KERNEL_LOG" 2>&1 &
    else
      (exec journalctl -k --follow -n 0 --no-pager -o short-monotonic) >> "$KERNEL_LOG" 2>&1 &
    fi
    WATCH_KMSG_PID=$!
  else
    say "WARNING: neither dmesg nor journalctl is available; no live kernel stream."
  fi
  if [ -n "$WATCH_KMSG_SOURCE" ]; then
    say "Live kernel stream started: $WATCH_KMSG_SOURCE"
    # Sync independently of snapshot(): that function can take several seconds or hang.
    (
      while :; do
        sleep 2
        sync "$KERNEL_LOG" 2>/dev/null || true
      done
    ) &
    WATCH_SYNC_PID=$!
  fi

  watch_stop_kernel() {
    if [ -n "${WATCH_SYNC_PID:-}" ]; then
      kill "$WATCH_SYNC_PID" 2>/dev/null || true
      wait "$WATCH_SYNC_PID" 2>/dev/null || true
      WATCH_SYNC_PID=""
    fi
    if [ -n "${WATCH_KMSG_PID:-}" ]; then
      kill "$WATCH_KMSG_PID" 2>/dev/null || true
      wait "$WATCH_KMSG_PID" 2>/dev/null || true
      WATCH_KMSG_PID=""
    fi
    # stdbuf may fork dmesg: after its wrapper exits, the follower can be
    # reparented and survive Ctrl-C. Stop only a dmesg writing this sidecar.
    for proc in /proc/[0-9]*/cmdline; do
      [ -r "$proc" ] || continue
      pid="${proc#/proc/}"; pid="${pid%/cmdline}"
      cmd="$(tr '\0' ' ' < "$proc" 2>/dev/null)" || continue
      [ "$cmd" = 'dmesg --follow-new --time-format=raw ' ] || continue
      output="$(readlink -f "/proc/$pid/fd/1" 2>/dev/null)" || continue
      [ "$output" = "$(readlink -f "$KERNEL_LOG")" ] || continue
      kill "$pid" 2>/dev/null || true
    done
    sync "$KERNEL_LOG" 2>/dev/null || true
    if [ -n "${WATCH_DRM_DEBUG_BEFORE:-}" ]; then
      if printf '%s\n' "$WATCH_DRM_DEBUG_BEFORE" > "$DRMPARAM"; then
        say "DRM debug restored to $WATCH_DRM_DEBUG_BEFORE"
      else
        say "WARNING: could not restore DRM debug to $WATCH_DRM_DEBUG_BEFORE"
      fi
    fi
  }
  trap 'watch_stop_kernel' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  prev=""
  while :; do
    cur="$(for c in /sys/class/drm/card*-DP-1 /sys/class/drm/card*-DP-2 /sys/class/drm/card*-HDMI-A-1; do
             printf '%s=%s ' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)"; done)"
    if [ "$cur" != "$prev" ]; then
      say "$(date '+%H:%M:%S')  connectors changed: $cur"
      prev="$cur"
      snapshot
      sync "$LOG" 2>/dev/null || true
    fi
    if [ -n "$WATCH_KMSG_PID" ] && ! kill -0 "$WATCH_KMSG_PID" 2>/dev/null; then
      say "WARNING: live kernel stream exited; inspect $KERNEL_LOG"
      WATCH_KMSG_PID=""
    fi
    sleep 2
  done
fi

snapshot
say "log: $LOG"
