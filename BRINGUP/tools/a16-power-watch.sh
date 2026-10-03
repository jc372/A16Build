#!/usr/bin/env bash
# a16-power-watch.sh -- watch the A16's power supplies while the machine is unplugged and plugged
#                       back in, and summarise what changed in each phase.  Read-only, no root.
#
#   bash a16-power-watch.sh                       # 120 s, a sample every 2 s
#   A16_POWER_SECONDS=300 A16_POWER_INTERVAL=5 bash a16-power-watch.sh
#   bash a16-power-watch.sh --summary FILE        # re-print the summary of an earlier log
#
# Why the shape: on this machine the interesting questions are not "is the battery there" but
# "does the gauge track reality" -- qcom-battmgr-bat exposes voltage_now, power_now,
# temperature, cycle count and the charge-control thresholds (the ASUS conservation mode lives at
# 75/80 %), while `capacity` and the charge counters can be *absent* or empty.  A percentage in
# the desktop shell comes from capacity, so an empty capacity looks like a dead battery gauge even
# when everything else works.  Sampling across an unplug/replug separates the two.
set -u

LOG="${A16_LOG:-$HOME/a16-payload/A16POWER-$(date +%Y%m%d-%H%M%S).log}"
[ -d "$(dirname "$LOG")" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG="/var/tmp/a16-power-$(date +%Y%m%d-%H%M%S).log"
[ "${1:-}" = "--summary" ] && { LOG="${2:-$LOG}"; only_summary=1; } || only_summary=0

BAT=/sys/class/power_supply/qcom-battmgr-bat
AC=/sys/class/power_supply/qcom-battmgr-ac
rd() { local p="$1"; if [ -e "$p" ]; then cat "$p" 2>/dev/null | tr -d '\n'; else printf 'ABSENT'; fi; }
field() { local v; v="$(rd "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf -- '-'; }

sample() {  # one line: epoch | ac | status | capacity | charge_now/full | V | I | W | temp
  printf '%s | ac=%s | %s | cap=%s | charge=%s/%s | %s uV | %s uA | %s uW | %s dC\n' \
    "$(date +%H:%M:%S)" "$(field "$AC/online")" "$(field "$BAT/status")" \
    "$(field "$BAT/capacity")" "$(field "$BAT/charge_now")" "$(field "$BAT/charge_full")" \
    "$(field "$BAT/voltage_now")" "$(field "$BAT/current_now")" "$(field "$BAT/power_now")" \
    "$(field "$BAT/temp")"
}

summarise() {
  awk -F' \\| ' '
    function num(x) { gsub(/^[a-z_]*=/, "", x); return (x == "-" ? "" : x) }
    {
      ac=$2; st=$3; cap=$4; v=num($6); w=num($8)
      key = ac " || " st " || " cap
      if (key != last) {
        if (last != "") printf "  phase %d: %s   (%d samples)\n", n, last, cnt
        last = key; cnt = 0; n++
        if (!seen[key]++) printf "    first seen at %s\n", $1
      }
      cnt++
      if (v != "") { if (minv == "" || v < minv) minv = v; if (v > maxv) maxv = v }
      if (w != "") { sumw += w; nw++ ; if (minw == "" || w < minw) minw = w; if (w > maxw) maxw = w }
    }
    END {
      if (last != "") printf "  phase %d: %s   (%d samples)\n", n, last, cnt
      if (minv != "") printf "\n  voltage across the run: %s .. %s uV\n", minv, maxv
      if (nw)         printf "  power   across the run: %s .. %s uW   (mean %d uW)\n", minw, maxw, sumw/nw
    }' "$1"
}

if [ "$only_summary" = 1 ]; then
  echo "=== summary of $LOG ==="; summarise "$LOG"; exit 0
fi

SECS="${A16_POWER_SECONDS:-120}"; INT="${A16_POWER_INTERVAL:-2}"
{
  echo "=== a16 power watch $(date +%Y%m%d-%H%M%S) -- ${SECS}s, a sample every ${INT}s ==="
  echo "# battery identity: manufacturer=$(field "$BAT/manufacturer") model=$(field "$BAT/model_name")"
  echo "#                 technology=$(field "$BAT/technology") cycles=$(field "$BAT/cycle_count")"
  echo "#                 charge_control_end_threshold=$(field "$BAT/charge_control_end_threshold")%  (ASUS conservation mode)"
  echo "# attributes that may not exist on this machine: capacity=$(rd "$BAT/capacity" | head -c 20)" \
       "charge_full=$(rd "$BAT/charge_full" | head -c 20) energy_full=$(rd "$BAT/energy_full" | head -c 20)"
  echo "#"
  [ -e "$BAT/capacity" ] || echo "# NOTE: $BAT/capacity does not exist at all -- no percentage can be read from this supply."
} >> "$LOG" 2>&1

printf 'sampling for %ss into %s  (unplug / plug back in whenever you like)\n' "$SECS" "$LOG"
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  sample | tee -a "$LOG"
  sleep "$INT"
done

{
  echo "#"
  echo "=== phases ==="
  summarise "$LOG"
  echo ""
  echo "=== what the phases mean ==="
  echo "  ac=1 + Capacities/charge: the gauge is reporting a percentage and counters -> a desktop"
  echo "      percentage can be trusted."
  echo "  cap=- (or 'ABSENT') in every phase -> the battery *is* present and the gauge reports V/W/"
  echo "      temperature/cycles, but no percentage and no charge counters exist on this machine."
  echo "      That is a driver/mapping gap, not a flat battery: conservation mode (charge stopped at"
  echo "      the 75/80 % threshold) also shows up as 'Not charging' while on AC."
  echo "  power_now negative while discharging / positive while charging, and a voltage that moves:"
  echo "      the sense path works, so the missing piece is only the capacity/charge mapping."
  echo "log: $LOG"
} >> "$LOG"
echo "--- summary ---"; summarise "$LOG"
echo "log: $LOG"
