#!/usr/bin/env bash
# a16-install-console-commands.sh -- put the two console commands where the shell finds them.
#
#   type this:   sudo bash ~/a16.sh commands        # install (one line, do this once)
#                bash ~/A16Build/BRINGUP/tools/a16-install-console-commands.sh status    # what is installed
#                sudo bash ~/a16.sh commands remove  # take the commands back out
#
# What it installs (symlinks, so the repo stays the single copy):
#
#   /usr/local/bin/reload_wifi -> BRINGUP/tools/a16-wifi-recover.sh    (the radio, after a resume wedge)
#   /usr/local/bin/lid_sleep   -> BRINGUP/tools/a16-sleep-test.sh      (the lid, and suspend)
#   /usr/local/bin/a16step     -> BRINGUP/tools/a16-step.sh            (the whole Wi-Fi/sleep job, one line)
#   /usr/local/bin/resume_log  -> BRINGUP/tools/a16-resume-log.sh      (the suspend/resume journal lines)
#   /usr/local/bin/reload_audio -> BRINGUP/tools/a16-audio-recover.sh  (the desktop sound, after a game)
#   ~/.local/bin/{reload_wifi,lid_sleep,a16step,resume_log,reload_audio}   (already on this user's PATH)
#   ~/reload_wifi, ~/lid_sleep, ~/a16step, ~/a16step.sh, ~/resume_log, ~/reload_audio  (for `sudo ~/a16step`)
#
# /usr/local/bin is what makes `sudo reload_wifi` work: sudo's secure_path includes it and, by
# default, not ~/.local/bin.  All of them answer `--help`.
#
# reload_audio is the exception to the sudo rule, and the inverse of the others: it drives the
# *user* session's PipeWire/WirePlumber, so it must be run as yourself, never with sudo --
# `sudo systemctl --user` would target root's own user manager and do nothing useful.
set -u

MODE="${1:-install}"
REPO=/home/jc/A16Build/BRINGUP/tools
HOME_DIR=/home/jc
BIN=/usr/local/bin
USER_BIN=/home/jc/.local/bin
declare -A SRC=( [reload_wifi]="$REPO/a16-wifi-recover.sh" [lid_sleep]="$REPO/a16-sleep-test.sh"
                 [a16step]="$REPO/a16-step.sh" [resume_log]="$REPO/a16-resume-log.sh"
                 [reload_audio]="$REPO/a16-audio-recover.sh" )
EXTRA_LINKS=( a16step.sh )   # both spellings, so `sudo ~/a16step` and `sudo bash ~/a16step.sh` work

say() { printf '%s\n' "$*"; }
[ "$MODE" = status ] || { [ "$(id -u)" = 0 ] || { say "This needs root.  Type exactly:"; say ""; say "    sudo bash ~/a16.sh commands"; say ""; exit 1; }; }

case "$MODE" in
  status)
    for n in "${!SRC[@]}"; do
      say "$n:"
      for d in "$BIN" "$USER_BIN" "$HOME_DIR"; do
        printf '   %-24s %s\n' "$d/$n" \
          "$( [ -L "$d/$n" ] && printf 'yes -> %s' "$(readlink "$d/$n")" || printf 'no')"
      done
    done
    exit 0 ;;
  install|remove) ;;
  *) say "usage: bash $0 [install|status|remove]"; exit 2 ;;
esac

rc=0
for n in "${!SRC[@]}"; do
  src="${SRC[$n]}"
  if [ "$MODE" = remove ]; then
    for p in "$BIN/$n" "$USER_BIN/$n" "$HOME_DIR/$n"; do
      if [ -L "$p" ]; then rm -f "$p" && say "   removed $p" || rc=1
      elif [ -e "$p" ]; then say "   $p is not a symlink -- left alone"; rc=1
      else say "   $p was not there"
      fi
    done
    continue
  fi
  [ -f "$src" ] || { say "   $src is missing -- is the repo still at /home/jc/A16Build ?"; rc=1; continue; }
  chmod +x "$src"
  for p in "$BIN/$n" "$USER_BIN/$n" "$HOME_DIR/$n"; do
    if [ -e "$p" ] && [ ! -L "$p" ]; then say "   $p exists and is not a symlink -- left alone"; rc=1; continue; fi
    ln -sfn "$src" "$p" && say "   $p -> $src" || rc=1
  done
done

if [ "$MODE" = install ]; then
  say ""
  say "checking that the commands resolve and answer --help:"
  for n in reload_wifi lid_sleep reload_audio; do
    if command -v "$n" >/dev/null 2>&1; then
      say "   $n -> $(command -v "$n")"
      "$n" --help | head -1 | sed 's/^/      /'
    else
      say "   $n is not on PATH ($BIN may not be in PATH for this shell)"
      rc=1
    fi
  done
  say ""
  say "Now type any of:   reload_wifi --help    lid_sleep --help    reload_audio --help"
  say "The radio one needs root for anything but 'status':  sudo reload_wifi"
  say "The audio one is the other way round -- no sudo, ever:  reload_audio"
fi
exit $rc
