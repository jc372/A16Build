#!/usr/bin/env bash
# a16-power-policy.sh -- this machine's power/lid policy.
#
# The strategy, chosen 2026-10-03: stop chasing sleep/wake.  A closed lid and the power button both
# POWER OFF; the machine boots in well under 20 s, so a power cycle replaces suspend.  Suspend stays
# available by hand (mem_sleep=s2idle) but nothing in the policy depends on it any more.
#
#   sudo bash a16-power-policy.sh apply     lid closed -> poweroff; power button -> poweroff
#   sudo bash a16-power-policy.sh status    what is in force right now, and the lid-switch reading
#   sudo bash a16-power-policy.sh revert    back to logind defaults (lid suspend, power key poweroff)
#   sudo bash a16-power-policy.sh login     one-line recovery for a black screen / failed login
#   sudo bash a16-power-policy.sh verify    (used by the others) re-read the effective properties
#
# Log: ~/a16-payload/power-policy-<timestamp>.log -- readable by you, root-only not required.
set -u

LOG_DIR="$HOME/a16-payload"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/power-policy-$(date +%Y%m%d-%H%M%S).log"
CONF=/etc/systemd/logind.conf.d/50-a16-lid.conf
DCONF_DIR=/etc/dconf/db/local.d
DCONF_FILE="$DCONF_DIR/00-a16-power"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
prop() { busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager "$1" 2>/dev/null | awk '{print $2}' | tr -d '"'; }

need_root() {
  if [ "$(id -u)" != 0 ]; then
    say "FATAL: run this as root:  sudo bash ~/a16.sh power $MODE"
    exit 1
  fi
}

write_conf() {   # $1 = lid value, $2 = power-key value
  install -d /etc/systemd/logind.conf.d
  {
    printf '# managed by a16-power-policy.sh -- what a closed lid and the power button do.\n'
    printf '# poweroff: the chosen policy (this machine replaces suspend with a power cycle).\n'
    printf '# suspend / ignore: available if you want them back (see revert).\n'
    printf '[Login]\n'
    printf 'HandleLidSwitch=%s\n'            "$1"
    printf 'HandleLidSwitchExternalPower=%s\n' "$1"
    printf 'HandleLidSwitchDocked=%s\n'      "$1"
    printf 'HandlePowerKey=%s\n'             "$2"
  } > "$CONF"
  systemctl reload systemd-logind 2>/dev/null
}

show_state() {
  local lid pk sess
  lid=$(prop HandleLidSwitch); pk=$(prop HandlePowerKey)
  say "  logind: HandleLidSwitch=$lid  HandlePowerKey=$pk"
  say "  config: $CONF"
  if [ "$(prop LidClosed)" = "true" ]; then
    say "  lid switch NOW: CLOSED  <- if the lid is physically open, STOP: the switch is lying and"
    say "                            a lid-closed rule would power the machine off at random."
  else
    say "  lid switch NOW: open"
  fi
  sess=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="jc"{n++} END{print n+0}')
  say "  jc sessions    : $sess   (a seat-less one before a graphical login is the trap -- see"
  say "                            notes/2026-10-03-session-manager-trap.md)"
  loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/      /' | tee -a "$LOG" >/dev/null
}

case "${1:-}" in

apply)
  MODE=apply; need_root
  say "=== power policy: APPLY (lid closed -> poweroff, power button -> poweroff) ==="
  say "log: $LOG"
  write_conf poweroff poweroff
  log "-- $CONF: HandleLidSwitch=poweroff (and external power + docked), HandlePowerKey=poweroff"

  # GNOME's own power-button handling, at the desktop.  A *system* dconf default applies where the
  # user has not set the key themselves; if the value below does not change after a re-login, set it
  # once inside your session with:
  #   gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'shutdown'
  install -d "$DCONF_DIR"
  { printf '[org/gnome/settings-daemon/plugins/power]\n'
    printf "power-button-action='shutdown'\n"; } > "$DCONF_FILE"
  if [ -f /etc/dconf/profile/user ]; then
    grep -q '^system-db:local' /etc/dconf/profile/user || \
      printf 'system-db:local\n' >> /etc/dconf/profile/user
  else
    { printf 'user-db:user\nsystem-db:local\n'; } > /etc/dconf/profile/user
  fi
  dconf update 2>/dev/null && log "-- dconf: $DCONF_FILE + /etc/dconf/profile/user (system-db:local)"
  say ""
  show_state
  say ""
  say "WHAT THIS MEANS: shutting the lid powers the machine off; the power button powers it off."
  say "  A power cycle is clean (systemd stops the session first), so apps that save their own"
  say "  state -- Firefox, Text Editor, Files -- come back as they were when you log in again."
  say "  Undocked or docked makes no difference now: all three lid cases power off."
  say "  From here: close the lid whenever you are done and boot again when you need it."
  log "apply done"
  ;;

status)
  MODE=status
  say "=== power policy: STATUS ==="
  say "log: $LOG"
  show_state
  say ""
  if command -v gsettings >/dev/null 2>&1; then
    # Read jc's value without su/runuser: point at their runtime dir and session bus directly.  This
    # works both as jc and as root, and never prompts.
    _u=$(getent passwd jc | cut -d: -f3 2>/dev/null); _rt="/run/user/${_u:-1000}"
    _p=$(XDG_RUNTIME_DIR="$_rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$_rt/bus" \
         gsettings get org.gnome.settings-daemon.plugins.power power-button-action 2>/dev/null)
    say "  GNOME power-button-action: ${_p:-? (no live session bus to read it from)}"
  fi
  say "  GNOME session restore    : not available (see notes/2026-10-03-shutdown-strategy.md)"
  say "  dconf system default     : $([ -f "$DCONF_FILE" ] && echo present || echo absent)"
  ;;

revert)
  MODE=revert; need_root
  say "=== power policy: REVERT to logind defaults (lid suspend, power key poweroff) ==="
  say "log: $LOG"
  write_conf suspend poweroff
  log "-- $CONF: HandleLidSwitch=suspend, HandlePowerKey=poweroff"
  rm -f "$DCONF_FILE"; dconf update 2>/dev/null
  log "-- dconf override removed"
  say ""
  show_state
  log "revert done"
  ;;

login)
  MODE=login; need_root
  say "=== login recovery (the session-manager trap, and the inactive-greeter case) ==="
  say "log: $LOG"
  say ""
  say "Sessions before:"
  loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/  /' | tee -a "$LOG" >/dev/null

  # 1. End the seat-less jc sessions.  A 'systemd --user' manager started by an SSH login (no seat)
  #    is what makes the graphical login die: GNOME reuses it and everything the session needs fails
  #    inside it.  Ending these -- including your SSH session, which is the point -- lets GNOME start
  #    a fresh manager, which is the whole fix.
  for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="jc" && $5=="-"{print $1}'); do
    log "-- ending seat-less jc session $s"
    loginctl terminate-session "$s" 2>/dev/null
  done
  sleep 2

  # 2. Restart the greeter, then put the panel on the greeter's VT and make its session active.
  #    A running compositor whose session is not the seat's active one paints nothing = black screen.
  systemctl restart gdm3 2>/dev/null
  sleep 4
  gid=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="gdm-greeter" && $5=="seat0"{print $1; exit}')
  if [ -n "$gid" ]; then
    loginctl activate "$gid" 2>/dev/null && log "-- activated greeter session $gid"
    t=$(loginctl show-session "$gid" -p TTY --value 2>/dev/null)
    case "$t" in tty*) chvt "${t#tty}" 2>/dev/null && log "-- panel switched to $t (the greeter's VT)";; esac
  else
    log "!! no greeter session found after the restart (check: systemctl status gdm3)"
  fi
  say ""
  say "Sessions after:"
  loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/  /' | tee -a "$LOG" >/dev/null
  say ""
  say "WHAT THIS MEANS: if the login screen is up now, log in and it should stick. If it is still"
  say "  black: the panel may be on the wrong VT -- the greeter lives on tty1 (Ctrl+Alt+F1), and"
  say "  'sudo chvt 1' does the same from here. If the panel is lit but dead, boot entry [1] (the"
  say "  firmware framebuffer) always gives you a visible console:  sudo bash ~/a16.sh default 1"
  log "login recovery done"
  ;;

*)
  say "usage: sudo bash a16-power-policy.sh {apply|status|revert|login}"
  say "  apply  : lid closed -> poweroff, power button -> poweroff   (the chosen strategy)"
  say "  status : what is in force, the lid-switch reading, session count"
  say "  revert : back to logind defaults (lid suspend, power key poweroff)"
  say "  login  : recover a black screen / failed graphical login in one line"
  exit 0
  ;;
esac
say ""
say "log: $LOG"
