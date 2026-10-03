#!/usr/bin/env bash
# a16-resume-recover.sh -- after a lid-close suspend the machine can come back in pieces: the panel dark,
# the USB-C controller dead (dock gone), the Wi-Fi radio wedged.  This puts back everything that CAN be
# put back, in one command, with a log you can read afterwards.
#
#   resume status                 read-only, no root: what state everything is in, and what the last
#                                 resume did (this is the one to run first)
#   sudo bash ~/a16.sh resume     diagnose, then every soft repair (panel, USB, Wi-Fi)
#   sudo bash ~/a16.sh resume panel|usb|wifi    only that half
#   sudo bash ~/a16.sh resume hook install|remove|status
#                                 run the soft repairs automatically after every resume
#   A16_I_KNOW=1 sudo bash ~/a16.sh resume hard
#                                 adds the rungs that can hang this kernel (read "what is not
#                                 recoverable" below -- they are not a fix, they are a last resort)
#
# WHAT IS RECOVERABLE, AND WHAT IS NOT  (evidence: BRINGUP/evidence/, docs/suspend.md)
#
#   panel   YES.  A resume can leave dp_aux_backlight bl_power=4 and card*-eDP-* enabled=disabled --
#                dark panel, machine and SSH fine.  Writing bl_power=0 alone is not enough: the output
#                has to be re-set, which a compositor does.  So the fix is unblank + restart gdm, and
#                only when the panel is actually dark (a good resume keeps your session).
#   USB     SOMETIMES.  The dock-facing controller is a platform device (a400000.usb -> dwc3-qcom ->
#                xhci-hcd.1.auto).  If it is alive but its devices did not re-enumerate, re-authorising
#                them brings them back.  If the controller itself died ("HC died; cleaning up" in the
#                journal), only unbinding/rebinding it has a chance, and that is a 'hard' rung.
#   Wi-Fi   NO, not when the firmware has wedged.  `reload_wifi` documents the failure precisely:
#                after the resume the WMI channel never answers again ("failed to resume core: -110"),
#                the soft rungs do nothing, and module reload ('modprobe -r') FROZE THE WHOLE MACHINE
#                and needed a hard reset.  So this script does the soft rungs and refuses the rest.
#                The real fix is prevention, and it is already installed:
#                    /etc/modprobe.d/a16-ath12k.conf: a16_keep_mhi_up=Y a16_skip_global_reset_on_resume=Y
#                which keeps the firmware running across the suspend instead of tearing it down.
#
# A HANG IS NOT RECOVERABLE.  If the machine never comes back out of the suspend (journal stops at
# "PM: suspend entry", no "PM: suspend exit"), no script can help -- nothing is running.  This platform
# has no ramoops/pstore backend and no /dev/watchdog, so a hung resume leaves no post-mortem either:
# the capture has to be live (no_console_suspend) or it is lost.  See docs/suspend.md.

set -u
say()  { printf '%s\n' "$*" | tee -a "$LOG" 2>/dev/null || printf '%s\n' "$*"; }
rule() { say "-------------------------------------------------------------"; }
log_only() { printf '%s\n' "$*" >> "$LOG" 2>/dev/null; }

PAYLOAD="${A16_PAYLOAD:-$HOME/a16-payload}"
mkdir -p "$PAYLOAD" 2>/dev/null
LOG="$PAYLOAD/resume-recover-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG" 2>/dev/null || true

BRINGUP="$HOME/A16Build/BRINGUP"
WIFI_TOOL="$BRINGUP/tools/a16-wifi-recover.sh"
SLEEP_TOOL="$BRINGUP/tools/a16-sleep-test.sh"

need_root() {
  if [ "$(id -u)" != 0 ]; then
    say "This needs root.  Type exactly:"
    say ""
    say "    sudo bash ~/a16.sh resume $*"
    say ""
    exit 1
  fi
}

# ------------------------------------------------------------------ panel
panel_is_dark() {
  local bl en
  bl=$(cat /sys/class/backlight/*/bl_power 2>/dev/null | head -1)
  en=$(cat /sys/class/drm/card*-eDP-*/enabled 2>/dev/null | head -1)
  # dark = backlight off (bl_power != 0) or the output not enabled
  [ "${bl:-0}" != "0" ] || [ "${en:-enabled}" != "enabled" ]
}

rung_panel() {
  rule
  say "-- panel"
  local bl en
  bl=$(cat /sys/class/backlight/*/bl_power 2>/dev/null | head -1)
  en=$(cat /sys/class/drm/card*-eDP-*/enabled 2>/dev/null | head -1)
  say "   bl_power=${bl:-?}  eDP enabled=${en:-?}  (0/enabled = a lit panel)"
  if ! panel_is_dark; then
    say "   VERDICT: the panel is fine -- nothing to do (a restart here would log you out for no reason)"
    return 0
  fi
  say "   the panel is dark.  Unblanking the backlight, then restarting gdm (a compositor has to"
  say "   re-set the mode; the backlight alone does not bring the picture back)."
  echo 0 > /sys/class/backlight/*/bl_power 2>/dev/null
  logger -t a16-resume-recover "panel dark (bl_power=${bl:-?} eDP=${en:-?}); restarting gdm"
  systemd-run --on-active=3 --unit=a16-resume-recover-gdm --collect systemctl restart gdm \
    || (setsid nohup bash -c 'sleep 3; systemctl restart gdm' >/dev/null 2>&1 &)
  say "   VERDICT: gdm restart scheduled in 3 s -- a fresh login screen is the cost of a dark resume."
}

# ------------------------------------------------------------------ USB
usb_report() {
  local c
  rule
  say "-- USB controllers and what is on them"
  for c in /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto; do
    [ -e "$c" ] || continue
    say "   $(basename "$c"): bound"
  done
  if [ -z "$(ls -d /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto 2>/dev/null)" ]; then
    say "   no xhci platform controller is bound to its driver -- the controller(s) are gone"
  fi
  local host dev n
  for host in /sys/bus/usb/devices/usb*; do
    [ -e "$host" ] || continue
    n=$(ls "$host"/*/product 2>/dev/null | wc -l)
    say "   $(basename "$host") ($(readlink -f "$host/.." 2>/dev/null | xargs basename 2>/dev/null)): ${n} device(s)"
    for dev in "$host"/*/; do
      [ -f "$dev/product" ] || continue
      say "      - $(cat "$dev/idVendor" 2>/dev/null):$(cat "$dev/idProduct" 2>/dev/null) $(cat "$dev/product" 2>/dev/null) [$(basename "$dev" | sed 's:/$::')] authorized=$(cat "$dev/authorized" 2>/dev/null)"
    done
  done
  say "   HC-died lines in this boot's journal: $(journalctl -k -b 2>/dev/null | grep -c 'HC died')"
}

# soft USB: re-authorise devices that are present but not usable
rung_usb_soft() {
  usb_report
  local dev did changed=0
  for dev in /sys/bus/usb/devices/*/; do
    [ -f "$dev/authorized" ] || continue
    did=$(basename "$dev" | sed 's:/$::')
    case "$did" in *-0:1.0|usb*) continue ;; esac   # skip root hubs and interfaces
    if [ "$(cat "$dev/authorized" 2>/dev/null)" = "0" ]; then
      say "   re-authorising $did $(cat "$dev/product" 2>/dev/null)"
      echo 0 > "$dev/authorized" 2>/dev/null; sleep 1; echo 1 > "$dev/authorized" 2>/dev/null
      changed=1
    fi
  done
  if [ "$changed" = 0 ]; then
    say "   VERDICT: nothing to re-authorise.  If a dock device is still missing, it is the controller"
    say "            rung that is needed (A16_I_KNOW=1 sudo bash ~/a16.sh resume usb)."
  else
    say "   VERDICT: re-authorised the devices marked unusable above -- check them again in a second:"
    sleep 2
    usb_report
  fi
}

# hard USB: unbind/rebind the platform controller (may hang a wedged controller -- gated)
rung_usb_hard() {
  say "-- USB: unbinding and rebinding the platform xhci controller(s)"
  say "   (this drops and re-enumerates everything on them; the internal keyboard and touchpad are"
  say "    NOT on USB on this machine, so they survive it)"
  local c name
  for c in /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto; do
    [ -e "$c" ] || continue
    name=$(basename "$c")
    say "   - $name"
    echo "$name" > /sys/bus/platform/drivers/xhci-hcd/unbind 2>/dev/null \
      || say "     unbind failed"
    sleep 2
    echo "$name" > /sys/bus/platform/drivers/xhci-hcd/bind 2>/dev/null \
      || say "     bind failed -- this controller stays dead until a reboot"
  done
  sleep 3
  usb_report
  say "   VERDICT: read the tree above.  The card reader / dock devices coming back means it worked."
}

# ------------------------------------------------------------------ Wi-Fi
power_line() {
  local ac bat now full w pct
  ac=$(cat /sys/class/power_supply/qcom-battmgr-ac/online 2>/dev/null)
  bat=$(cat /sys/class/power_supply/qcom-battmgr-bat/status 2>/dev/null)
  now=$(cat /sys/class/power_supply/qcom-battmgr-bat/energy_now 2>/dev/null)
  full=$(cat /sys/class/power_supply/qcom-battmgr-bat/energy_full 2>/dev/null)
  w=$(cat /sys/class/power_supply/qcom-battmgr-bat/power_now 2>/dev/null)
  pct="?"
  if [ -n "${now:-}" ] && [ -n "${full:-}" ] && [ "${full:-0}" != "0" ]; then
    pct=$(awk -v n="$now" -v f="$full" 'BEGIN{printf "%.0f", n*100/f}')
  fi
  printf 'AC=%s (%s) battery=%s %s%%' "${ac:-?}" \
    "$([ "${ac:-0}" = "1" ] && echo plugged || echo unplugged)" "${bat:-?}" "$pct"
  if [ -n "${w:-}" ] && [ "${w#-}" != "$w" ]; then
    printf '   discharging at %.1f W' "$(awk -v w="$w" 'BEGIN{printf "%.1f", -w/1e6}')"
  fi
}

# the PCIe link the radio hangs off: 'Link Down' here is the signature of the lost-radio resume
pcie_link_line() {
  local rp=/sys/bus/pci/devices/0004:00:00.0
  if [ -e "$rp/current_link_speed" ]; then
    printf 'root port %s: %s x%s   (max %s x%s)' "$(basename $rp)" \
      "$(cat $rp/current_link_speed 2>/dev/null)" "$(cat $rp/current_link_width 2>/dev/null)" \
      "$(cat $rp/max_link_speed 2>/dev/null)" "$(cat $rp/max_link_width 2>/dev/null)"
  else
    printf 'root port %s: no link-speed attributes' "$(basename $rp)"
  fi
}

wifi_report() {
  rule
  say "-- Wi-Fi"
  local dev="0004:01:00.0" link
  if ! lspci -s "$dev" 2>/dev/null | grep -q .; then
    say "   $dev is NOT on the PCI bus -- the radio's PCIe link is down (see reload_wifi / 'wifisleep forensics')"
  else
    say "   $dev present: $(lspci -s "$dev" 2>/dev/null | cut -d' ' -f2-)"
    link=$(lspci -vv -s "$dev" 2>/dev/null | grep -m1 "LnkSta:" | sed 's/^\s*//')
    say "   ${link:-LnkSta: (not reported)}"
  fi
  say "   $(pcie_link_line)"
  say "   wlan interfaces: $(ls /sys/class/net 2>/dev/null | grep -E '^wl' | tr '\n' ' ')"
  say "   NetworkManager : $(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | grep -E '^wl' | tr '\n' ' ')"
  say "   firmware wedge lines in this boot: $(journalctl -k -b 2>/dev/null | grep -cE 'failed to resume core|timeout while waiting for restart complete')"
  say "   keep-MHI-up (what prevents the wedge): $(grep -h 'keep_mhi_up' /etc/modprobe.d/*.conf 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
}

rung_wifi_soft() {
  wifi_report
  say "   -- soft rungs: NetworkManager, then the supplicant"
  systemctl restart NetworkManager 2>&1 | log_only
  sleep 2
  nmcli networking off 2>&1 | log_only; sleep 1; nmcli networking on 2>&1 | log_only
  say "   nmcli after the restart:"
  say "     $(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | grep -E '^wl' | tr '\n' ' ')"
  say "   VERDICT: if the interface is up and the firmware is answering, this fixed it.  If it is still"
  say "            down, the firmware is wedged -- that is NOT recoverable in software on this kernel"
  say "            (module reload froze the machine; see reload_wifi --help), and a reboot is the only way."
}

rung_wifi_hard() {
  say "-- Wi-Fi: the driver-teardown rungs (A16_I_KNOW=1)"
  say "   REFUSED BY DESIGN unless you accept a possible hard reset.  What is documented:"
  say "     h2 assert/deassert + h3 PCI remove/rescan, then h4 modprobe -r ath12k_wifi7 ath12k"
  say "   -- and on a wedged radio h4 FROZE THE WHOLE MACHINE (BRINGUP/evidence, reload_wifi header)."
  say "   The tool that owns these rungs is reload_wifi; use it directly if you want them:"
  say "       A16_I_KNOW=1 sudo reload_wifi hard"
}

# ------------------------------------------------------------------ last resume, from the journal
last_resume() {
  rule
  say "-- suspend/resume history (this boot and the three before it)"
  local b events n_in n_out first=1
  for b in 0 -1 -2 -3; do
    events=$(journalctl -b "$b" --no-pager -o short-iso 2>/dev/null \
      | grep -E "PM: suspend entry|PM: suspend exit|failed to suspend|failed to resume|A16: resume|HC died|failed to resume core|restart complete")
    [ -n "$events" ] || continue
    n_in=$(printf '%s\n' "$events" | grep -c "PM: suspend entry")
    n_out=$(printf '%s\n' "$events" | grep -c "PM: suspend exit")
    say "   boot $b: ${n_in} suspend entry, ${n_out} exit$([ "$n_in" != "$n_out" ] && echo '   <- one never came back')"
    if [ "$first" = 1 ]; then
      first=0
      printf '%s\n' "$events" | tail -14 | sed 's/^/      /' | tee -a "$LOG"
    fi
  done
  [ "$first" = 1 ] && say "   no suspend/resume activity in this boot or the three before it"
  say ""
  say "   read it like this: an entry with no matching 'PM: suspend exit' = the machine never came back"
  say "   (a hard reset was needed, and nothing was logged after the freeze).  'HC died' names the USB"
  say "   controller; 'failed to resume core: -110' is the radio's firmware staying dead."
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ================================================================== main
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  status|"")
    rule; say "=== a16-resume-recover status  $(date '+%Y-%m-%d %H:%M:%S') ==="
    say "kernel: $(uname -r)   boot id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    say "power : $(power_line)"
    panel_is_dark && say "-- panel: DARK (bl_power=$(cat /sys/class/backlight/*/bl_power 2>/dev/null | head -1))" \
                   || say "-- panel: lit"
    usb_report
    wifi_report
    last_resume
    say ""
    say "log: $LOG"
    exit 0 ;;
esac

need_root "$@"

case "${1:-all}" in
  all|"")
    rule; say "=== a16-resume-recover  $(date '+%Y-%m-%d %H:%M:%S')   kernel=$(uname -r) ==="
    say "log: $LOG"
    rung_panel
    rung_usb_soft
    rung_wifi_soft
    last_resume
    rule
    say "done.  What is still broken and why: read the VERDICT lines above; docs/suspend.md lists the"
    say "open items, and 'resume_log' prints the suspend/resume history in one short command."
    ;;
  panel) rung_panel ;;
  usb)
    if [ "${2:-soft}" = "hard" ]; then
      [ "${A16_I_KNOW:-0}" = "1" ] || { say "The hard USB rung unbinds the controller -- add A16_I_KNOW=1 if you mean it."; exit 1; }
      rung_usb_soft; rung_usb_hard
    else
      rung_usb_soft
    fi ;;
  wifi)
    [ "${A16_I_KNOW:-0}" = "1" ] || { say "Wi-Fi: the soft rungs only (the driver teardown can freeze this machine)."; }
    rung_wifi_soft ;;
  hard)
    [ "${A16_I_KNOW:-0}" = "1" ] || { say "Refusing: add A16_I_KNOW=1 to run the rungs that can hang this kernel."; exit 1; }
    rung_panel; rung_usb_soft; rung_usb_hard; rung_wifi_soft; rung_wifi_hard ;;
  hook)
    HOOK=/usr/lib/systemd/system-sleep/a16-resume-recover
    case "${2:-}" in
      remove) rm -f "$HOOK" && say "-- removed $HOOK"; exit 0 ;;
      status) [ -f "$HOOK" ] && say "-- installed: $HOOK" || say "-- not installed"; exit 0 ;;
    esac
    say "-- writing $HOOK"
    cat > "$HOOK" <<HOOKEOF
#!/bin/bash
# A16: after a resume, put back what a suspend can take: the panel (if dark), USB-C devices that did
# not re-enumerate, and the Wi-Fi soft rungs.  Only the soft repairs -- nothing here can hang, and
# nothing here restarts gdm unless the panel is actually dark.  Written by a16-resume-recover.sh.
case "\${1:-}" in post) ;; *) exit 0 ;; esac
sleep 5
A16_HOOK=1 "$BRINGUP/tools/a16-resume-recover.sh" all >> "$PAYLOAD/resume-recover-hook.log" 2>&1
exit 0
HOOKEOF
    chmod 755 "$HOOK"
    say "   installed: $HOOK   (mode 755)"
    say ""
    say "   what it does on a resume: waits 5 s, then runs the soft rungs once and appends to"
    say "   $PAYLOAD/resume-recover-hook.log.  A resume that came back clean is left alone."
    say "   remove it with:  sudo bash ~/a16.sh resume hook remove"
    ;;
  *) say "usage: sudo bash ~/a16.sh resume [status|all|panel|usb [hard]|wifi|hard|hook install|remove|status]"; exit 2 ;;
esac
exit 0
