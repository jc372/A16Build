#!/usr/bin/env bash
# audio-watch - record what the audio graph actually does when sound stops and starts.
#
# USER SESSION ONLY. Never run this with sudo: it reads your own PipeWire session,
# and sudo would sample root's (empty) graph and tell you nothing.
#
# Usage:   audio-watch [seconds]        default 900 (15 min)
#          reproduce while it runs: play something, stop, wait ~10 s, play again
# Log:     ~/a16-payload/audio-watch-<timestamp>.log
#
# What it prints, one line per CHANGE (so a quiet log means a quiet graph):
#   HH:MM:SS  sink=<running|suspended|idle> streams=<n> <app names>  amps=<SDW status x4>
#
# Reading it: if a dropout lines up with sink=suspended -> the node was torn down
# (idle-suspend); if the sink stays running while sound stops -> the fault is upstream
# of PipeWire (amps, DSP) and kernel-side evidence is what matters.

set -u
DUR=${1:-900}
DIR=$HOME/a16-payload
mkdir -p "$DIR"
LOG="$DIR/audio-watch-$(date +%Y%m%d-%H%M%S).log"
START=$(date -Is)

{
  echo "# audio-watch started $START (${DUR}s)  log=$LOG"
  echo "# reproduce: play something, stop, count to 10, play again"
} | tee "$LOG"

probe() {
  pw-dump 2>/dev/null | python3 -c '
import json, sys
sink = "?"; n = 0; apps = set()
try:
    objs = json.load(sys.stdin)
except Exception:
    print("parse-error streams=- -"); raise SystemExit
for o in objs:
    info = o.get("info") or {}
    p = info.get("props") or {}
    mc = p.get("media.class", "")
    if mc == "Audio/Sink":
        sink = info.get("state", "?")
    elif mc.startswith("Stream/"):
        n += 1
        apps.add((p.get("application.name") or p.get("node.name") or "?"))
print("sink=%s streams=%d %s" % (sink, n, ",".join(sorted(apps))[:60]))
'
}

prev=""
while :; do
  amps=$(cat /sys/bus/soundwire/devices/sdw*/status 2>/dev/null | tr '\n' ',')
  cur="$(probe)  amps=${amps%,}"
  if [ "$cur" != "$prev" ]; then
    printf '%s  %s\n' "$(date +%H:%M:%S)" "$cur" | tee -a "$LOG"
    prev="$cur"
  fi
  [ "$(( $(date +%s) - $(date -d "$START" +%s) ))" -ge "$DUR" ] && break
  sleep 1
done

{
  echo "# --- audio lines from the journal during this window ---"
  journalctl --user --since "$START" --no-pager -o short-iso 2>/dev/null \
    | grep -iE "spa\.alsa|wireplumber|pipewire|suspend|resume|no data available" | tail -40
  echo "# audio-watch finished $(date -Is)"
} | tee -a "$LOG"
