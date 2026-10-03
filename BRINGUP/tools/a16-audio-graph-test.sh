#!/usr/bin/env bash
# a16-audio-graph-test.sh -- does the DSP actually consume a stream on this machine?
#
#   sudo bash /home/jc/a16-payload/a16-audio-graph-test.sh all          # swap topology, reload card, play, measure
#   sudo bash /home/jc/a16-payload/a16-audio-graph-test.sh tplg romulus # only swap the topology (reboot to make it take)
#   sudo bash /home/jc/a16-payload/a16-audio-graph-test.sh tplg crd     # put the reference topology back
#   sudo bash /home/jc/a16-payload/a16-audio-graph-test.sh reload       # reload the card module
#   sudo bash /home/jc/a16-payload/a16-audio-graph-test.sh probe        # play + measure the live card only
#
# Why measure `hw_ptr` twice: on the CRD reference topology the card appears, the ALSA
# stream reaches *RUNNING*, and `hw_ptr` never leaves 0 while `appl_ptr` parks at the buffer
# depth -- the DSP opened the stream and never consumed a frame, which is why playback
# blocks (video stalls) and only a single "crack" is audible when the amps power up.  The
# point of this script is to answer "did a different topology change that" with numbers,
# not with "no sound".
set -u

CARD="${A16_CARD:-0}"
PAYLOAD="/home/jc/a16-payload"
TONE="$PAYLOAD/a16-tone.wav"
FW="/lib/firmware/qcom/glymur"
TARGET="$FW/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin.zst"
CRD="$FW/GLYMUR-CRD-tplg.bin.zst"
ROMULUS="/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst"
LOG="${A16_LOG:-$PAYLOAD/A16AUDIO-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }
run() { # run <label> <cmd...>: real status, output captured
  local label="$1"; shift
  local out status
  out="$("$@" 2>&1)"; status=$?
  say "### [$label] \$ $*"
  say "$out"
  say "### exit: $status"
  return $status
}

: > "$LOG" 2>/dev/null || LOG=/var/tmp/a16-audio-graph.log
: > "$LOG"
say "[a16-audio] === a16-audio-graph-test $(date +%Y%m%d-%H%M%S) ==="
[ "$(id -u)" = 0 ] || { say "[a16-audio] FATAL: run with sudo"; exit 1; }

# ------------------------------------------------------------------ topology
cmd_tplg() {
  local which="${1:-crd}" src=""
  case "$which" in
    crd|CRD)         src="$CRD" ;;
    romulus|ROMULUS) src="$ROMULUS" ;;
    xps|XPS)         src="/lib/firmware/qcom/x1e80100/X1E80100-Dell-XPS-13-9345-tplg.bin.zst" ;;
    yoga|YOGA)       src="/lib/firmware/qcom/x1e80100/X1E80100-LENOVO-Yoga-Slim7x-tplg.bin.zst" ;;
    *)
      if [ -f "$which" ]; then src="$which"
      else
        say "[a16-audio] unknown topology '$which' (crd|romulus|xps|yoga, or a path).  Installed graphs:"
        for f in /lib/firmware/qcom/*/*tplg* /lib/firmware/qcom/*/*/*tplg* /lib/firmware/qcom/glymur/*tplg*; do
          [ -f "$f" ] || continue
          printf '    %-78s streams: %s | devices: %s\n' "$f" \
            "$(zstdcat "$f" 2>/dev/null | strings | grep -oE 'stream[0-9]+\.(pcm_decoder|pcm_encoder)' | sort -u | paste -sd, -)" \
            "$(zstdcat "$f" 2>/dev/null | strings | grep -oE 'device[0-9]+\.codec_dma_[rt]x1' | sort -u | paste -sd, -)" | tee -a "$LOG"
        done
        return 2
      fi ;;
  esac
  sec "topology -> $which"
  [ -f "$src" ] || { say "[a16-audio] FATAL: $src missing"; return 2; }
  say "[a16-audio] source : $src  $(stat -c %s "$src") bytes sha256 $(sha256sum "$src" | cut -c1-16)"
  if [ ! -f "$TARGET.a16bak" ]; then
    cp -a "$TARGET" "$TARGET.a16bak" 2>/dev/null && say "[a16-audio] kept the previous target as $TARGET.a16bak"
  fi
  install -m 0644 "$src" "$TARGET" || { say "[a16-audio] install FAILED"; return 2; }
  say "[a16-audio] installed: $TARGET  $(stat -c %s "$TARGET") bytes sha256 $(sha256sum "$TARGET" | cut -c1-16)"
  say "[a16-audio] (the driver asks for this name from DMI: $(tr -d '\0' < /proc/device-tree/model))"
}

# ------------------------------------------------------------------ reload
cmd_reload() {
  sec "reload the card module"
  run "rmmod"  modprobe -r snd_soc_x1e80100
  sleep 1
  run "modprobe" modprobe snd_soc_x1e80100
  sleep 2
  run "cards" cat /proc/asound/cards
  say "--- kernel since the reload ---"
  journalctl -k --since "-15s" --no-pager 2>/dev/null | grep -iE 'asoc|tplg|wsa|swr|soundwire|snd-x1e80100' | tail -12 | sed 's/^/    /' | tee -a "$LOG"
}

# ------------------------------------------------------------------ mixer route
set_route() {
  amixer -c"$CARD" sset 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' on >/dev/null 2>&1 \
    && say "    route on : WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1"
  for c in 'WSA WSA_RX0 Digital Mute' 'WSA WSA_RX1 Digital Mute' 'WSA2 WSA_RX0 Digital Mute' 'WSA2 WSA_RX1 Digital Mute'; do
    amixer -c"$CARD" sset "$c" off >/dev/null 2>&1 && say "    unmuted  : $c"
  done
  for c in 'WSA WSA_RX0 Digital' 'WSA WSA_RX1 Digital' 'WSA2 WSA_RX0 Digital' 'WSA2 WSA_RX1 Digital'; do
    amixer -c"$CARD" sset "$c" 100% >/dev/null 2>&1 && say "    volume   : $c 100%"
  done
  for c in 'TweeterLeft PA' 'TweeterRight PA' 'WooferLeft PA' 'WooferRight PA'; do
    amixer -c"$CARD" sset "$c" 6 >/dev/null 2>&1 && say "    amp gain : $c 6"
  done
}

pcm_status() { cat "/proc/asound/card$CARD/pcm0p/sub0/status" 2>/dev/null; }
field() { pcm_status | awk -v k="$1" '$1==k":" {print $2}'; }

# ------------------------------------------------------------------ probe
cmd_probe() {
  sec "probe: play and watch hw_ptr"
  say "[a16-audio] card: $(cat /proc/asound/cards | tr -s ' ' | tail -n +2 | head -2 | paste -sd' ' -)"
  [ -s "$TONE" ] || { say "[a16-audio] FATAL: no tone at $TONE"; return 2; }
  say "[a16-audio] setting the speaker path:"; set_route

  # the sink has to be un-muted for a real test, and the session's own stream first
  if command -v wpctl >/dev/null 2>&1; then
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}" wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 >/dev/null 2>&1
    say "[a16-audio] session sink unmuted ($(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000} wpctl status 2>/dev/null | grep -m1 'Built-in Audio' | tr -s ' '))"
  fi

  say "[a16-audio] playing the tone straight at plughw:$CARD,0 for ~6 s -- listen for two rising tones"
  aplay -q -D "plughw:$CARD,0" "$TONE" >/dev/null 2>&1 &
  local pid=$!
  sleep 1
  local s1 h1 a1 s2 h2 a2 t1 t2
  s1="$(pcm_status)"; h1="$(field hw_ptr)"; a1="$(field appl_ptr)"
  sleep 4
  s2="$(pcm_status)"; h2="$(field hw_ptr)"; a2="$(field appl_ptr)"
  say "  t+1s : state=$(pcm_status | awk '$1=="state:"{print $2}') hw_ptr=$h1 appl_ptr=$a1"
  say "  t+5s : state=$(pcm_status | awk '$1=="state:"{print $2}') hw_ptr=$h2 appl_ptr=$a2"
  say "  raw status at t+5s:"; printf '%s\n' "$s2" | sed 's/^/    /' | tee -a "$LOG"
  wait $pid 2>/dev/null; local rc=$?
  say "  aplay exit=$rc"
  local st1 st2
  st1="$(printf '%s' "$s1" | awk '$1=="state:"{print $2}')"
  st2="$(printf '%s' "$s2" | awk '$1=="state:"{print $2}')"
  if [ "$rc" != 0 ] || [ -z "$st2" ] || [ "$st2" = closed ]; then
    say "  VERDICT: the stream never opened (aplay exit=$rc, PCM state='${st2:-none}') -- this graph does not"
    say "           reach the amps at all.  The reason is in the kernel lines below (APM/DSP port errors,"
    say "           SoundWire bus errors), NOT in hw_ptr -- do not read this as 'the DSP consumed nothing'."
  elif [ "$st1" = RUNNING ] && [ -n "${h1:-}" ] && [ "$h1" != "$h2" ]; then
    say "  VERDICT: the DSP consumed the stream (state=$st1, hw_ptr $h1 -> $h2) -- this graph drives the amps"
  elif [ "$st1" = RUNNING ]; then
    say "  VERDICT: DSP opened the stream (RUNNING) and consumed nothing (hw_ptr $h1 -> $h2) -- frozen path"
  else
    say "  VERDICT: inconclusive (state '$st1' -> '$st2', hw_ptr '$h1' -> '$h2') -- read the kernel lines"
  fi
  say ""
  say "  --- kernel (last 25 relevant lines) ---"
  journalctl -k --since "-90s" --no-pager 2>/dev/null | grep -iE 'asoc|wsa|swr|soundwire|apm|dai|pcm|timeout|parity|clsh' | tail -25 | sed 's/^/    /' | tee -a "$LOG"
}

[ $# -gt 0 ] || { printf 'usage: %s [tplg crd|romulus|xps|yoga|<path>] [reload] [probe] [all]\n' "$0"; exit 2; }

# run *every* argument as a subcommand, in order -- `tplg crd reload probe` is three steps,
# and a single-subcommand dispatch silently ignored the rest (how a restore "changed nothing")
while [ $# -gt 0 ]; do
  case "$1" in
    tplg)   cmd_tplg "${2:-crd}"; shift || break; [ $# -gt 0 ] && shift ;;
    reload) cmd_reload; shift ;;
    probe)  cmd_probe; shift ;;
    all)    cmd_tplg "${2:-romulus}"; shift || break; [ $# -gt 0 ] && shift; cmd_reload; cmd_probe ;;
    *)      say "unknown subcommand '$1' (tplg|reload|probe|all)"; exit 2 ;;
  esac
done
say ""
say "[a16-audio] log: $LOG"
exit 0
