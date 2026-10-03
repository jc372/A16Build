#!/usr/bin/env bash
# a16-session-apps.sh -- remember which apps are open, reopen them at the next login.
#
# Scope, as agreed: RELAUNCH ONLY.  The app comes back; the app's own "restore"/history is the
# operator's to click.  Nothing here tries to restore tabs or terminal contents -- the point is
# fewer steps, not session teleportation.
#
# Two halves, both shell:
#   hook   : a user service that queries the running apps on the way down (graphical-session.target
#            stopping = logout, reboot, or a lid/power-button poweroff).  Ordered `After=app.slice`,
#            so at stop time it runs BEFORE the session's apps are killed -- that ordering is what
#            makes a plain query at shutdown reliable.  A 60 s timer is written but is NOT enabled
#            (install --with-timer): it is only a fallback if a teardown ever beats the hook.
#   startup: an XDG autostart entry that runs after the user logs in and reopens the list.
#
# Where apps come from (verified on this machine, 2026-10-03):
#   native apps : user units  app-gnome-<desktop-id>-<pid>.scope / app-<desktop-id>@<token>.service
#   snap apps   : SYSTEM units snap.<snap>.<app>.<hash>.scope  -- e.g. firefox and this Ubuntu's
#                 terminal are snaps, so their desktop entries are NOT under /usr/share/applications
#                 but under /var/lib/snapd/desktop/applications/<snap>_<app>.desktop
#   flatpak     : system + user exports in /var/lib/flatpak/exports/share/applications and
#                 ~/.local/share/flatpak/exports/share/applications
# An id is kept only if a desktop entry is found for it AND that entry does not set
# NoDisplay=true / Hidden=true.  That single rule is what separates the operator's apps from session
# plumbing (org.gnome.Evolution-alarm-notify, update-notifier, snapd-desktop-integration) with no
# hardcoded list.  The snapshot stores the DESKTOP ID (the desktop file's basename), which is exactly
# what `gtk-launch` wants.
#
#   a16-session-apps save      snapshot now (the hook calls this)
#   a16-session-apps list      what is open now, and what is remembered
#   a16-session-apps restore   reopen the remembered apps that are not already running
#   a16-session-apps install   write + enable the shutdown hook, the timer and the login startup
#   a16-session-apps uninstall remove them
#   a16-session-apps status    what is installed, and the last snapshot
#
# State: ~/.local/state/a16/session-apps   Logs: ~/a16-payload/session-apps-<date>.log
set -u

STATE_DIR="$HOME/.local/state/a16"
STATE="$STATE_DIR/session-apps"
UNIT_DIR="$HOME/.config/systemd/user"
AUTOSTART="$HOME/.config/autostart"
BIN="$HOME/.local/bin/a16-session-apps"
SRC="$(readlink -f "$0")"
LOG_DIR="$HOME/a16-payload"
LOG="$LOG_DIR/session-apps-$(date +%Y%m%d).log"
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SELF=a16-session-apps

mkdir -p "$STATE_DIR" "$LOG_DIR" "$HOME/.local/bin"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }
say() { printf '%s\n' "$*"; }

# every place a desktop entry can live, including the snap and flatpak export dirs
app_dirs() {
  printf '%s\n' "$HOME/.local/share/applications" /usr/local/share/applications \
                /usr/share/applications /var/lib/snapd/desktop/applications \
                /var/lib/flatpak/exports/share/applications \
                "$HOME/.local/share/flatpak/exports/share/applications"
  local d; IFS=:; for d in ${XDG_DATA_DIRS:-}; do printf '%s/applications\n' "$d"; done
}

# find_desktop <app-id-or-snap-app> -> path of the desktop entry, or nothing.
# Exact <id>.desktop first; then the snap convention <snap>_<app>.desktop / <x>-<app>.desktop.
find_desktop() {
  local id="$1" d f
  while read -r d; do
    [ -d "$d" ] || continue
    [ -f "$d/$id.desktop" ] && { printf '%s\n' "$d/$id.desktop"; return 0; }
    f=$(find "$d" -maxdepth 1 -name "*[_-]$id.desktop" 2>/dev/null | head -1)
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  done < <(app_dirs)
  return 1
}

keep_id() {   # app id -> 0 if it is a real, user-visible app
  local f; f=$(find_desktop "$1") || return 1
  grep -qE '^(NoDisplay|Hidden)=true' "$f" && return 1
  return 0
}

# ---- what is open right now ----------------------------------------------------------------
unit_ids() {
  # native user units -- NOTE the .slice form: D-Bus activated apps (ptyxis, this image's terminal)
  # live in app-dbus-:1.NN-<bus-name>.slice, not in an app-*.scope, so the slice must be queried too.
  systemctl --user list-units 'app-*.scope' 'app-*.service' 'app-*.slice' --no-legend --plain 2>/dev/null |
    awk '{print $1}'
  # snap scopes: system (snap.<snap>.<app>.<hash>.scope) and user (services/scopes only, not mounts)
  systemctl list-units 'snap.*.scope' --no-legend --plain 2>/dev/null | awk '{print $1}'
  systemctl --user list-units 'snap.*.service' 'snap.*.scope' --no-legend --plain 2>/dev/null | awk '{print $1}'
}

to_id() {   # unit name -> desktop id (or the snap's <snap>_<app> id)
  local u="$1" id snap app
  u="$(printf '%s' "$u" | sed 's/\\x2d/-/g')"      # units are name-escaped: app-dbus\x2d:1.1\x2dfoo
  case "$u" in
    app-*)
      id="${u#app-}"; id="${id#gnome-}"; id="${id%@*}"
      id="${id%-[0-9]*.scope}"; id="${id%-[0-9]*.service}"; id="${id%.slice}"
      # D-Bus activated app: app-dbus-:1.NN-<bus-name> -- the bus name IS the desktop id here
      # (org.gnome.Ptyxis has /usr/share/applications/org.gnome.Ptyxis.desktop).  No blocklist: bus
      # names without a real desktop entry (org.a11y.atspi.Registry, org.freedesktop.FileManager1,
      # org.gnome.OnlineAccounts, ...) are dropped by the desktop-entry filter in current_apps().
      if [ "${id#dbus-}" != "$id" ]; then
        id="${id#dbus-}"; id="${id#:1.}"; id="${id#*-}"
      fi
      printf '%s\n' "$id" ;;
    snap.*)
      snap=$(printf '%s' "$u" | cut -d. -f2)
      app=$(printf '%s'  "$u" | cut -d. -f3)
      # snap.<snap>.<app>-<uuid>.scope is the form seen on this image (firefox:
      # snap.firefox.firefox-9bb5bb7b-323a-4f83-bb07-57a0b6da9de4.scope), and it lives in the USER
      # manager, not the system one.  Drop the UUID, then the desktop id is the exported
      # <snap>_<app> name (firefox_firefox.desktop), which resolves exactly.
      app=$(printf '%s' "$app" | sed -E 's/-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$//')
      case "$snap" in snapd*|""|-*) return 0 ;; esac     # daemons, not apps
      [ -n "$app" ] && printf '%s_%s\n' "$snap" "$app" && return 0
      printf '%s\n' "$snap" ;;
  esac
}

current_apps() {
  local u id f
  unit_ids | while read -r u; do
    [ -n "$u" ] || continue
    id=$(to_id "$u"); [ -n "$id" ] || continue
    case "$id" in "$SELF"|*-*desktop) continue ;; esac   # D-Bus-activated apps are NOT skipped: ptyxis
                                                         # is one, and the desktop-entry filter decides
    f=$(find_desktop "$id") || continue
    grep -qE '^(NoDisplay|Hidden)=true' "$f" && continue
    printf '%s\n' "$(basename "$f" .desktop)"        # store the desktop id, what gtk-launch wants
  done | sort -u
}

cmd_save() {
  local n
  mkdir -p "$STATE_DIR"
  current_apps > "$STATE.new"
  n=$(grep -c . "$STATE.new" 2>/dev/null || echo 0)
  gp=$(grep -c . "$STATE" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ] && [ "${1:-}" != "--force" ] && [ "$gp" -gt 0 ]; then
    log "save: nothing running; keeping the previous list ($gp app(s))"
    rm -f "$STATE.new"; say "nothing running -- kept the previous list"; return 0
  fi
  mv "$STATE.new" "$STATE"
  log "save: $n app(s): $(tr '\n' ' ' < "$STATE")"
  say "saved $n app(s) for the next login:"
  sed 's/^/  /' "$STATE"
}

cmd_list() {
  say "open now:"; current_apps | sed 's/^/  /'
  say ""
  if [ -s "$STATE" ]; then
    say "remembered (last snapshot $(date -r "$STATE" '+%Y-%m-%d %H:%M')):"
    sed 's/^/  /' "$STATE"
  else
    say "nothing remembered yet"
  fi
}

cmd_restore() {
  [ -s "$STATE" ] || { say "nothing to restore"; return 0; }
  local stamp="$STATE_DIR/.last-restore"
  if [ -f "$stamp" ] && [ $(( $(date +%s) - $(date -r "$stamp" +%s) )) -lt 120 ]; then
    say "restore already ran less than 2 minutes ago -- skipping"; return 0
  fi
  : > "$stamp"
  local open id f launched=0
  open="$(current_apps)"
  while read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$open" | grep -qx "$id" && { log "restore: $id already running"; continue; }
    f=$(find_desktop "$id") || { log "restore: $id has no desktop entry any more -- skipped"; continue; }
    if command -v gtk-launch >/dev/null 2>&1; then
      gtk-launch "$id" >/dev/null 2>&1 || gio launch "$f" >/dev/null 2>&1
    else
      gio launch "$f" >/dev/null 2>&1
    fi
    launched=$((launched+1)); log "restore: launched $id ($f)"
    sleep 1
  done < "$STATE"
  say "reopened $launched app(s).  Apps that offer their own restore (Firefox, editors, Files) will"
  say "show it when they come up -- click it there."
}

cmd_install() {
  mkdir -p "$UNIT_DIR" "$AUTOSTART" "$HOME/.local/bin"
  [ -L "$BIN" ] || ln -sfn "$SRC" "$BIN"
  # Why After=app.slice: the session's app units live under app.slice, and systemd stops units in
  # reverse start order -- starting after the slice means we are stopped BEFORE the apps are killed,
  # so the snapshot runs while they are still there.  That is what makes a plain "query at shutdown"
  # reliable and removes the need for a periodic snapshot.
  cat > "$UNIT_DIR/a16-session-apps-save.service" <<EOF
[Unit]
Description=a16: snapshot the open apps on the way down
PartOf=graphical-session.target
After=app.slice

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=$BIN save

[Install]
WantedBy=graphical-session.target
EOF
  cat > "$UNIT_DIR/a16-session-apps-save.timer" <<EOF
[Unit]
Description=a16: keep the open-app list fresh (fallback if the ordered shutdown hook misses)

[Timer]
OnStartupSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF
  cat > "$AUTOSTART/a16-restore-session.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=a16: reopen my apps
Comment=Reopen the apps that were open at the last shutdown (a16-session-apps restore)
Exec=$BIN restore
X-GNOME-Autostart-Delay=10
NoDisplay=true
EOF
  systemctl --user daemon-reload 2>/dev/null
  systemctl --user enable a16-session-apps-save.service 2>/dev/null
  if [ "${1:-}" = "--with-timer" ]; then
    systemctl --user enable --now a16-session-apps-save.timer 2>/dev/null
    log "install: service + autostart + FALLBACK TIMER enabled; symlink $BIN -> $SRC"
  else
    log "install: service + autostart written (no timer); symlink $BIN -> $SRC"
  fi
  say "installed:"
  say "  $UNIT_DIR/a16-session-apps-save.service   (snapshot on the way down, ordered After=app.slice"
  say "                                             so it runs before the apps are killed)"
  say "  $AUTOSTART/a16-restore-session.desktop    (reopen after login, 10 s delay)"
  say "  $BIN -> $SRC"
  say "  timer: NOT enabled (nothing periodic runs).  Add it only if a shutdown ever comes up empty:"
  say "         bash ~/a16.sh apps install --with-timer"
  say ""
  say "WHAT THIS MEANS: shut down however you like (lid, power button); at the next login your apps"
  say "  reopen.  Apps already running are not opened twice.  Nothing restores tab contents -- each"
  say "  app offers its own restore if it has one."
  say ""
  say "TEST IT: keep your apps open, shut down, log in.  Then:  bash ~/a16.sh apps status"
  say "  A snapshot timestamp from just before the shutdown, listing your apps, means the query at"
  say "  shutdown worked.  'nothing running -- kept the previous list' in $LOG means the teardown beat"
  say "  the hook -- that is the one case where the timer earns its place."
}

cmd_uninstall() {
  systemctl --user disable --now a16-session-apps-save.timer 2>/dev/null
  systemctl --user disable a16-session-apps-save.service 2>/dev/null
  rm -f "$UNIT_DIR/a16-session-apps-save.service" "$UNIT_DIR/a16-session-apps-save.timer" \
        "$AUTOSTART/a16-restore-session.desktop"
  systemctl --user daemon-reload 2>/dev/null
  say "removed (the remembered list in $STATE is kept)"
}

cmd_status() {
  say "hook installed   : $([ -f "$UNIT_DIR/a16-session-apps-save.service" ] && echo yes || echo no)"
  say "timer installed  : $([ -f "$UNIT_DIR/a16-session-apps-save.timer" ] && echo yes || echo no)"
  say "startup installed: $([ -f "$AUTOSTART/a16-restore-session.desktop" ] && echo yes || echo no)"
  say "timer state      : $(systemctl --user is-active a16-session-apps-save.timer 2>/dev/null)"
  say "symlink on PATH  : $(readlink "$BIN" 2>/dev/null || echo missing)"
  if [ -s "$STATE" ]; then
    say "last snapshot    : $(date -r "$STATE" '+%Y-%m-%d %H:%M')  ($(grep -c . "$STATE") app(s))"
    sed 's/^/    /' "$STATE"
  else
    say "last snapshot    : none yet"
  fi
  say "log              : $LOG"
}

case "${1:-}" in
  save)      shift; cmd_save "$@" ;;
  list)      cmd_list ;;
  restore)   cmd_restore ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) say "usage: a16-session-apps {save|list|restore|install|uninstall|status}"
     say "  save    : remember the apps open now (the shutdown hook calls this)"
     say "  list    : what is open now, and what is remembered"
     say "  restore : reopen the remembered apps that are not already running"
     say "  install : write + enable the shutdown hook, the 60 s timer and the login startup"
     say "  status  : what is installed and when the last snapshot was taken" ;;
esac
