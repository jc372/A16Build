#!/usr/bin/env bash
# a16-sound-test.sh -- does the sound card actually reach the speakers?
#
#     bash /home/jc/a16-payload/a16-sound-test.sh
#     bash /home/jc/a16-payload/a16-sound-test.sh --state     # just print state, play nothing
#
# No sudo needed.  Writes nothing except a mixer-state backup in your home dir and
# the log in /var/tmp.  The expected good result is: the sink is offered, the ALSA
# stream reaches RUNNING, and you HEAR two rising tones on both sides.
set -u
CARD=0
LOG="/var/tmp/a16-sound-test.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }

# the test tone (regenerated if missing, so this script stands alone)
TONE="/home/jc/a16-payload/a16-tone.wav"
if [ ! -s "$TONE" ]; then
  python3 - "$TONE" <<'PY' >/dev/null 2>&1 && echo "[a16] tone regenerated: $TONE"
import sys, wave, struct, math
sr, amp = 48000, 5200
def seg(f, t): return [int(amp*math.sin(2*math.pi*f*i/sr)) for i in range(int(sr*t))]
s = seg(523.25,0.6)+[0]*int(sr*0.15)+seg(784.0,0.6)+[0]*int(sr*0.15)+seg(1046.5,0.9)
w = wave.open(sys.argv[1],'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
w.writeframes(b''.join(struct.pack('<hh',v,v) for v in s)); w.close()
PY
fi

sec "card"
cat /proc/asound/cards 2>&1 | tee -a "$LOG"

sec "sink offered to the session"
if command -v wpctl >/dev/null 2>&1; then
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" wpctl status 2>&1 | sed -n '/Audio/,/Sources/p' | tee -a "$LOG"
else
  say "wpctl not present"
fi

sec "mixer state (before)"
alsactl -f "$HOME/a16-mixer-state.txt" store "$CARD" >/dev/null 2>&1 \
  && say "saved current mixer state to $HOME/a16-mixer-state.txt (restore: alsactl -f ~/a16-mixer-state.txt restore $CARD)"
for c in 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 'WSA WSA_RX0 Digital Mute' 'WSA WSA_RX1 Digital Mute' \
         'WSA2 WSA_RX0 Digital Mute' 'WSA2 WSA_RX1 Digital Mute' 'WSA WSA_RX0 Digital' 'TweeterLeft PA' \
         'TweeterRight PA' 'WooferLeft PA' 'WooferRight PA' 'WSA EAR SPKR PA Gain'; do
  printf '  %-44s %s\n' "$c" "$(amixer -c$CARD sget "$c" 2>/dev/null | tail -1)" | tee -a "$LOG"
done

if [ "${1:-}" = "--state" ]; then say ""; say "log: $LOG"; exit 0; fi

sec "setting the speaker path"
amixer -c$CARD cset numid=95 on >/dev/null 2>&1 && say "route on: WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1"
for c in 'WSA WSA_RX0 Digital Mute' 'WSA WSA_RX1 Digital Mute' 'WSA2 WSA_RX0 Digital Mute' 'WSA2 WSA_RX1 Digital Mute'; do
  amixer -c$CARD sset "$c" off >/dev/null 2>&1 && say "unmuted: $c"
done
for c in 'WSA WSA_RX0 Digital' 'WSA WSA_RX1 Digital' 'WSA2 WSA_RX0 Digital' 'WSA2 WSA_RX1 Digital'; do
  amixer -c$CARD sset "$c" 100% >/dev/null 2>&1 && say "volume 100%: $c"
done
for c in 'TweeterLeft PA' 'TweeterRight PA' 'WooferLeft PA' 'WooferRight PA'; do
  amixer -c$CARD sset "$c" 6 >/dev/null 2>&1 && say "amp gain 6: $c"
done
amixer -c$CARD sset 'WSA EAR SPKR PA Gain' 'G_DEFAULT' >/dev/null 2>&1 && say "PA gain: G_DEFAULT"

sec "playing (listen now: two rising tones, twice)"
say "-- via the session server (what apps use) --"
if command -v pw-play >/dev/null 2>&1; then
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" pw-play "$TONE" 2>&1 | tee -a "$LOG"; say "pw-play exit=$?"
else
  say "pw-play not present"
fi
say "-- PCM state during/after that --"
cat /proc/asound/card$CARD/pcm0p/sub0/status 2>&1 | tee -a "$LOG" | head -4

say ""
say "-- directly to the card (bypasses the server) --"
if [ -s "$TONE" ]; then
  aplay -q -D plughw:$CARD,0 "$TONE" 2>&1 | tee -a "$LOG"; say "aplay exit=$?"
else
  say "no tone file at $TONE"
fi

sec "what the kernel said"
journalctl -k --no-pager -n 120 2>/dev/null | grep -iE 'wsa|apm|gpr|pcm|dai|asoc|dsp|timeout' | tail -12 | tee -a "$LOG"

sec "done"
say "log: $LOG"
say "if you heard nothing:  bash $0 --state   and send me the log"
say "if it worked:          the speaker path is live; next is a UCM profile so GNOME routes to it"
exit 0
