#!/usr/bin/env bash
# a16-gdm-session-fix.sh -- prevent the lingering jc user manager from pre-empting GNOME login.
# Run: sudo bash ~/a16.sh gdmfix
# This disables logind lingering for jc. It does NOT kill/restart the current desktop.
# The change takes full effect on the next normal shutdown and boot. The user service manager
# (including hermes-gateway.service) will then start with the first jc login, rather than at boot.
set -u

USER_NAME=jc
UID_NUM=$(id -u "$USER_NAME" 2>/dev/null || true)
LOG_DIR="/home/$USER_NAME/a16-payload"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/gdm-session-fix-$(date +%Y%m%d-%H%M%S).log"
log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*" | tee -a "$LOG"; }

if [ "$(id -u)" -ne 0 ]; then
  log "FATAL: run as root: sudo bash ~/a16.sh gdmfix"
  exit 1
fi
if [ -z "$UID_NUM" ] || [ ! -d "/home/$USER_NAME" ]; then
  log "FATAL: expected account $USER_NAME and its home directory"
  exit 1
fi

log "=== GDM login fix: disable lingering for $USER_NAME (UID $UID_NUM) ==="
log "Before: $(loginctl show-user "$USER_NAME" -p Linger -p Sessions -p Display --value 2>/dev/null | tr '\n' ' ')"
log "Evidence: linger is currently enabled; user@1000.service starts before the greeter and the manager session predates the graphical login. GNOME can then reuse this seat-less manager."
log "Applying: loginctl disable-linger $USER_NAME"
if ! loginctl disable-linger "$USER_NAME"; then
  log "FATAL: loginctl disable-linger failed; no session or GDM restart was attempted"
  exit 1
fi

linger=$(loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || true)
if [ "$linger" != "no" ] || [ -e "/var/lib/systemd/linger/$USER_NAME" ]; then
  log "FATAL: verification failed: Linger=$linger; inspect loginctl show-user $USER_NAME"
  exit 1
fi
log "VERIFIED: Linger=no and /var/lib/systemd/linger/$USER_NAME is absent."
log "The current desktop/user manager was left untouched. Do not restart GDM now."
log "Next: save work, shut down normally, then boot and log in locally before opening SSH as jc."
log "Expected: user@${UID_NUM}.service starts with the graphical login; Hermes Gateway starts when that user manager starts."
log "Tradeoff: the Hermes Gateway will not run before the first jc login after boot."
log "log: $LOG"
