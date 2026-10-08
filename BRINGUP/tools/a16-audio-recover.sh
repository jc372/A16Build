#!/usr/bin/env bash
# a16-audio-recover.sh -- bring the desktop sound back after the session node dies, without rebooting.
#
# The operator-facing command is `reload_audio` (symlinked into ~/.local/bin and into the home
# directory by tools/a16-install-console-commands.sh, and into /usr/local/bin by
# `sudo bash ~/a16.sh commands`).
#
#   reload_audio --help             this text
#   reload_audio status             read-only, no root: what is wrong and what it means
#   reload_audio                    recover (default): restart the sound server, verify, report
#   reload_audio test               play a quiet 440 Hz tone and prove the DSP consumes it
#   reload_audio history [days]     how often this has happened (the "is it worth a watcher" number)
#   reload_audio log                the tail of the last run's log
#
# NOT with sudo.  This drives the *user* session's PipeWire/WirePlumber; `sudo systemctl --user`
# would target root's own user manager instead of the session that owns the sound card.
#
# WHY THIS EXISTS
# ---------------
# 2026-10-06, after an x86 game over Proton: the desktop fell back to "Dummy Output" and stayed
# there.  The sound card was never the problem -- `aplay -D hw:0,1` opened and played fine the whole
# time.  What died was WirePlumber's session node, at the moment the node tried to resume:
#
#   pipewire:    pw.node: (alsa_output.platform-sound.playback.1.0-56) suspended -> error
#                (Start error: No data available)
#   pipewire:    spa.alsa: 'hw:0,1': playback open failed: No data available
#   pipewire:    mod.adapter: can't get format: No data available
#   wireplumber: s-monitors: Failed to create ALSA node
#                alsa_output.platform-sound.playback.1.0: Object activation aborted:
#                PipeWire proxy destroyed
#
# ENODATA there is the same errno this platform produces on the amplifier resume path, so the
# trigger is plausibly the game releasing the PCM and the immediate resume racing the codec.
# The important part is what happens next: PipeWire puts the node in error, WirePlumber *destroys*
# it, the null sink (node.name = auto_null, shown as "Dummy Output") takes its slot, and nothing
# ever retries -- the ALSA monitor only re-creates the node on a card event.  So it looks permanent
# and a reboot fixes it, but a reboot is not the cure: a WirePlumber restart is, and that is what
# this does (`systemctl --user restart wireplumber`, no root).
#
# Three different faults all show up as "no sound", and this script keeps them apart:
#
#   1. the session node died        -> sink is auto_null while `aplay -D hw:0,1` works
#                                      -> FIXABLE LIVE (this script, rung 1)
#   2. amplifiers not attached      -> SoundWire device status is not "Attached"
#                                      -> report only; needs a reboot or kernel work (see
#                                         tools/a16-audio-attach.sh and docs/audio.md)
#   3. no card at all / PCM refuses -> card missing, or the PCM open fails at device level
#                                      -> firmware/UCM class; not a session problem, not fixable here
#
# NEVER write to /sys/bus/soundwire/drivers/*/bind to "fix" fault 2: it blocks in the kernel
# (unkillable D state) and takes the sound card with it -- measured, see a16-audio-attach.sh.
#
# Logged to ~/a16-payload/audio-recover-<timestamp>.log, so it survives a reboot.
# Env overrides: A16_WAIT (seconds to wait for the sink to come back, default 15), A16_DRY (1 = print,
# run nothing), A16_FORCE (1 = restart even when the sink already looks right), A16_DAYS (default 7),
# A16_LOG, A16_PCM (ALSA PCM probed at device level, default hw:0,1).
set -u

MODE="${1:-recover}"
WAIT="${A16_WAIT:-15}"
DRY="${A16_DRY:-0}"
FORCE="${A16_FORCE:-0}"
DAYS="${A16_DAYS:-7}"
PCM="${A16_PCM:-hw:0,1}"
LOG="${A16_LOG:-/home/jc/a16-payload/audio-recover-$(date +%Y%m%d-%H%M%S).log}"
PY="$(command -v /usr/bin/python3 || command -v python3 || true)"

say()  { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }

usage() {
  cat <<'EOF'
reload_audio -- bring the desktop sound back after the session node dies, without rebooting.

usage:
  reload_audio --help            this text
  reload_audio status            read-only, no root: the card, the sink, the amplifiers, the verdict
  reload_audio                   recover: if the sink is the null fallback, restart the sound server,
                                 wait for the real sink, and report what it was
  reload_audio test              play a 440 Hz tone at 5% through the sink and read the PCM while it
                                 plays: hw_ptr advancing = the DSP is consuming samples
  reload_audio history [days]    count the node deaths in the journal (default 7 days).  This is the
                                 number that says whether a watcher is worth installing
  reload_audio log               the tail of the most recent run log

what this fixes (2026-10-06, after an x86 game over Proton):
  WirePlumber's ALSA node died on a failed resume (ENODATA) and was destroyed, leaving the null
  sink ("Dummy Output") in its place with nothing to re-create the real one.  The card was fine
  throughout.  A WirePlumber restart is the cure; a reboot only hides it.

what this does NOT fix:
  - amplifiers not "Attached" on the SoundWire bus  -> reboot or kernel work (tools/a16-audio-attach.sh)
  - no sound card / the PCM refusing to open        -> firmware/UCM class, see docs/audio.md
  Do NOT write to /sys/bus/soundwire/drivers/*/bind: it hangs in the kernel in D state.

never run this with sudo: it drives the user session's PipeWire/WirePlumber, and `sudo
systemctl --user` would talk to root's user manager instead.

log: ~/a16-payload/audio-recover-<timestamp>.log
env: A16_WAIT (s, default 15), A16_DRY=1 (print, run nothing), A16_FORCE=1 (restart anyway),
     A16_DAYS (default 7), A16_PCM (default hw:0,1).
EOF
}

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

case "$MODE" in
  status|recover|test|history|log) ;;
  *) say "usage: reload_audio [status|recover|test|history|log]   (reload_audio --help)"; exit 2 ;;
esac

# ------------------------------------------------------------------ root refusal
if [ "$(id -u)" = 0 ]; then
  say ""
  say "! Do not run this with sudo."
  say "  It talks to the *user* session's PipeWire/WirePlumber.  Run as yourself, as root not at all:"
  say ""
  say "      reload_audio"
  say ""
  say "  (As root, systemctl --user targets root's user manager, which owns no sound card.)"
  exit 1
fi

[ -n "$PY" ] || { [ "$MODE" = test ] && { say "python3 is needed to generate the test tone -- not found"; exit 1; }; }

# ------------------------------------------------------------------ probes
sink_node() { wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | sed -n 's/^[ *]*node\.name = "\(.*\)"/\1/p'; }
sink_desc() { wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | sed -n 's/^[ *]*node\.description = "\(.*\)"/\1/p'; }
sink_id()   { wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | sed -n 's/^id \([0-9]*\),.*/\1/p'; }
volume()    { wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null; }
card_line() { sed -n '2p;3p' /proc/asound/cards 2>/dev/null | tr -s ' '; }
pcm_dev()   { ls /dev/snd/pcm* 2>/dev/null | tr '\n' ' '; }

# amplifier attach state: count everything that is not "Attached"
amps_off() { local n=0; for d in /sys/bus/soundwire/devices/sdw:*/; do [ -d "$d" ] || continue
              [ "$(cat "$d/status" 2>/dev/null)" = Attached ] || n=$((n+1)); done; echo "$n"; }
amps_list() { for d in /sys/bus/soundwire/devices/sdw:*/; do [ -d "$d" ] || continue
                printf '      %-30s %s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null)"; done; }

# is there a sound card at all?  (/proc/asound/cards has no usable st_size, so test its content)
card_present() { grep -qE '^[[:space:]]*[0-9]+ \[' /proc/asound/cards 2>/dev/null; }

# device-level probe: can ALSA open the playback PCM, and if not, is that a fault?
#   0 = opens fine        3 = busy (the sound server holds it -- normal, not a fault)
#   1 = refused (the real device-level fault)
# While PipeWire is driving the card it keeps hw:0,1 open, so a direct aplay legitimately gets
# EBUSY; that must not be reported as "the card is broken".
PCM_ERR=""
pcm_probe() {
  local w rc
  PCM_ERR=""
  w="$(mktemp "${TMPDIR:-/tmp}/a16-pcmprobe-XXXXXX.wav")"
  "$PY" -c '
import wave, struct, sys
r=48000; n=int(r*0.15)
w=wave.open(sys.argv[1],"wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(r)
w.writeframes(struct.pack("<%dh" % (2*n), *([0]*(2*n)))); w.close()
' "$w" 2>/dev/null || { rm -f "$w"; PCM_ERR="could not generate a probe file (is python3 there?)"; return 1; }
  [ "$DRY" = 1 ] && { rm -f "$w"; PCM_ERR="(dry run: not opening $PCM)"; return 0; }
  aplay -q -D "$PCM" "$w" 2>"${TMPDIR:-/tmp}/a16-pcmprobe.err"; rc=$?
  rm -f "$w"
  [ "$rc" = 0 ] && return 0
  PCM_ERR="$(head -1 "${TMPDIR:-/tmp}/a16-pcmprobe.err" 2>/dev/null | sed 's/^aplay: [a-z]*:[0-9]*: //' | tr -s ' ')"
  case "$PCM_ERR" in *busy*|*Busy*) return 3 ;; esac
  return 1
}
pcm_text() { case "$1" in
               0) printf 'opens fine' ;;
               3) printf 'busy -- the sound server is holding it (normal, not a fault)' ;;
               *) printf 'FAILED (%s) -- device-level fault' "$PCM_ERR" ;;
             esac; }

# journal signature of the node death.  'Failed to create ALSA node' happens once per incident and
# is what this counts; the PCM-open failures are the supporting lines (several per incident).
NODE_DEATH_RE="Failed to create ALSA node|'hw:0,1': playback open failed|alsa_output\.[^)]*\) suspended -> error"
incidents()  { journalctl --user --since "$1 days ago" --no-pager 2>/dev/null | grep -cE 'Failed to create ALSA node'; }
pcm_fails()  { journalctl --user --since "$1 days ago" --no-pager 2>/dev/null | grep -cE "'hw:0,1': playback open failed"; }
death_last()  { journalctl --user --since "$1 days ago" -o short-iso --no-pager 2>/dev/null | grep -E "$NODE_DEATH_RE" | tail -"${2:-5}"; }

wait_for_real_sink() {   # returns 0 when the default sink is no longer the null fallback
  local t=0
  [ "$DRY" = 1 ] && return 0
  while [ "$t" -lt "$WAIT" ]; do
    [ "$(sink_node)" != auto_null ] && [ -n "$(sink_node)" ] && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

dump_status() {
  rule
  say "-- the sound card (kernel side)"
  if card_present; then
    say "   card: $(card_line)"
    say "   devs: $(pcm_dev)"
    pcm_probe; say "   pcm $PCM: $(pcm_text $?)"
  else
    say "   NO SOUND CARD at all (/proc/asound/cards lists none) -- fault type 3"
    say "   pcm $PCM: not probed (there is no card to open)"
  fi
  rule
  say "-- the session sink (PipeWire side)"
  if ! command -v wpctl >/dev/null 2>&1; then
    say "   wpctl is not installed -- is PipeWire present?"
  else
    say "   default sink : $(sink_id) $(sink_desc) [$(sink_node)]"
    say "   volume       : $(volume)"
  fi
  rule
  say "-- the four speaker amplifiers (SoundWire)"
  amps_list
  say "   not Attached: $(amps_off) of 4"
  say "   [(a non-zero count here is the other silent-speaker fault: report only, reboot or kernel"
  say "     work -- and NEVER write to /sys/bus/soundwire/drivers/*/bind, it hangs the machine.)]"
  rule
  say "-- how often the session node has died in the last $DAYS days"
  say "   incidents   : $(incidents "$DAYS")   (each one is one destroyed ALSA node)"
  say "   pcm failures: $(pcm_fails "$DAYS")   (supporting lines, several per incident)"
  death_last "$DAYS" 4 | sed 's/^/      /'
  rule
  say "-- verdict"
  local node; node="$(sink_node)"
  if ! card_present; then
    say "   FAULT 3: there is no sound card.  Not a session problem and not fixable here -- the"
    say "            firmware/UCM class.  See docs/audio.md.  A reboot is the usual way out."
  elif [ "$node" = auto_null ]; then
    say "   FAULT 1: the session node died and the null fallback is in its place."
    say "            The card is there, so this is fixable right now:   reload_audio"
  elif [ -z "$node" ]; then
    say "   No default sink at all -- see the two sections above."
  else
    say "   The real sink is in place ('$(sink_desc)')."
    [ "$(amps_off)" != 0 ] && say "   ...but $(amps_off) amplifier(s) are not Attached: expect thin or one-sided sound."
    say "   To prove sound is really flowing:   reload_audio test"
  fi
}

# ------------------------------------------------------------------ rung 1 / 2
rung_wireplumber() {
  rule
  say "-- rung 1: restart WirePlumber (systemctl --user restart wireplumber)"
  if [ "$DRY" = 1 ]; then say "   (dry run: not running it)"; return 0; fi
  systemctl --user restart wireplumber || { say "   restart returned non-zero"; return 1; }
  wait_for_real_sink && { say "   sink is back: $(sink_desc) [$(sink_node)]"; return 0; }
  say "   still the null fallback after ${WAIT}s"; return 1
}

rung_pipewire() {
  rule
  say "-- rung 2: restart the whole user sound stack (pipewire-pulse, pipewire, wireplumber)"
  if [ "$DRY" = 1 ]; then say "   (dry run: not running it)"; return 0; fi
  systemctl --user restart pipewire-pulse.service pipewire.service wireplumber.service || true
  wait_for_real_sink && { say "   sink is back: $(sink_desc) [$(sink_node)]"; return 0; }
  say "   still the null fallback after ${WAIT}s"; return 1
}

# ------------------------------------------------------------------ tone test
tone_test() {
  local w hw1 hw2 st
  rule
  say "-- tone test: 440 Hz at 5% through the default sink"
  w="$(mktemp "${TMPDIR:-/tmp}/a16-tone-XXXXXX.wav")"
  if [ "$DRY" = 1 ]; then say "   (dry run: not playing anything)"; rm -f "$w"; return 0; fi
  "$PY" -c '
import wave, struct, math, sys
r=48000; dur=3.0; amp=int(32767*0.05); n=int(r*dur)
w=wave.open(sys.argv[1],"wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(r)
w.writeframes(b"".join(struct.pack("<hh", int(amp*math.sin(2*math.pi*440*i/r)),
                                    int(amp*math.sin(2*math.pi*440*i/r))) for i in range(n)))
w.close()
' "$w" || { say "   could not generate the tone"; rm -f "$w"; return 1; }
  say "   playing (this should be audible from the speakers, quietly)"
  pw-play "$w" & local pid=$!
  sleep 1
  st="$(sed -n 's/^state: //p' /proc/asound/card0/pcm1p/sub0/status 2>/dev/null)"
  hw1="$(sed -n 's/^hw_ptr *: //p' /proc/asound/card0/pcm1p/sub0/status 2>/dev/null)"
  say "   while playing: state=${st:-<none>}  hw_ptr=$hw1"
  sleep 1
  hw2="$(sed -n 's/^hw_ptr *: //p' /proc/asound/card0/pcm1p/sub0/status 2>/dev/null)"
  wait "$pid" 2>/dev/null; rm -f "$w"
  rule
  if [ -z "$hw1" ]; then
    say "RESULT: nothing is playing on the card at all (no PCM state) -- the sink is not reaching it."
    say "        Run 'reload_audio status'."
  elif [ "$hw1" != "$hw2" ]; then
    say "RESULT: the DSP is consuming samples -- hw_ptr moved $hw1 -> $hw2."
    say "        If you heard the tone, audio is genuinely healthy; if you did not, the sound is"
    say "        reaching the DSP but not the speakers, which is the amplifier fault, not this one."
  else
    say "RESULT: the stream is RUNNING but hw_ptr is frozen at $hw1 -- attached but not consumed."
    say "        That is the old failure mode from notes/2026-09-16, not the session-node one."
  fi
  return 0
}

# ------------------------------------------------------------------ main
CMD_NAME="reload_audio"
say "=== $CMD_NAME  (a16-audio-recover.sh)  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
say "kernel: $(uname -r)   boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
say "log   : $LOG"

case "$MODE" in
  status) dump_status; say ""; rule; say "log: $LOG"; exit 0 ;;

  history)
    rule
    say "-- session node deaths in the last $DAYS days"
    say "   incidents   : $(incidents "$DAYS")   (each one is one destroyed ALSA node)"
    say "   pcm failures: $(pcm_fails "$DAYS")   (supporting lines, several per incident)"
    say ""
    say "   most recent:"
    death_last "$DAYS" 10 | sed 's/^/      /'
    rule
    say "   reading it:"
    say "     0    -> has not happened in $DAYS days"
    say "     a few, all on one or two days -> the game-session trigger, as on 2026-10-06"
    say "     climbing, or spread over many days -> worth a watcher (a small systemd user unit that"
    say "     notices auto_null and runs 'reload_audio' on its own).  Not installed yet."
    say ""
    say "   change the window with:   reload_audio history 30   (or A16_DAYS=30 reload_audio history)"
    exit 0 ;;

  log)
    last="$(ls -1t /home/jc/a16-payload/audio-recover-*.log 2>/dev/null | head -1)"
    [ -n "$last" ] || { say "no audio-recover log yet"; exit 1; }
    say "most recent log: $last"; rule; tail -60 "$last"; exit 0 ;;

  test) tone_test; say ""; rule; say "log: $LOG"; exit 0 ;;
  recover) ;;
esac

# ---- recover
dump_status
rule

if [ "$(sink_node)" != auto_null ] && [ "$FORCE" != 1 ] && [ "$DRY" != 1 ]; then
  say "Nothing to fix: the default sink is already the real card ('$(sink_desc)')."
  say "             (To restart the sound server anyway:  A16_FORCE=1 reload_audio)"
  say "             (To check it end to end:                 reload_audio test)"
  rule
  say "log: $LOG"
  exit 0
fi

if ! card_present && [ "$DRY" != 1 ]; then
  rule
  say "! There is no sound card at all, so restarting the sound server cannot help.  This is the"
  say "  firmware/UCM class of fault -- see docs/audio.md.  Check the amplifiers and the card above;"
  say "  a reboot is the usual way out."
  rule
  say "log: $LOG"
  exit 1
fi

say "-- climbing: the first rung that brings the real sink back is the last one that runs"
WON=""
if rung_wireplumber; then WON="wireplumber"; elif rung_pipewire; then WON="pipewire"; fi

rule
if [ "$DRY" = 1 ]; then
  say "RESULT: dry run -- nothing was run.  Without A16_DRY=1 this restarts WirePlumber (rung 1),"
  say "        then the whole user sound stack (rung 2) if that was not enough."
elif [ -n "$WON" ]; then
  say "RESULT: sound is back -- the real sink is in place again after rung '$WON'."
  say "        No reboot, no root.  Applications do not need to be restarted: they re-attach"
  say "        themselves, which is how the desktop volume control finds the sink again."
  say "        To prove the DSP is consuming it:   reload_audio test"
else
  say "RESULT: the NULL sink is still the default after both rungs."
  say "        The card was usable, so this is not the session node dying: look at the amplifier"
  say "        states above.  With amplifiers not Attached there is nothing a session restart can do."
  say "        Reboot, and record it:   reload_audio history"
fi
rule
say "log: $LOG"
exit 0
