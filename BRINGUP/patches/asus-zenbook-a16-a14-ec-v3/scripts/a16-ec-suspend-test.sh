#!/bin/bash
# a16 EC suspend/resume proof -- run with:
#   sudo bash ~/a16-payload/a16-ec-suspend-test.sh probe
#   sudo bash ~/a16-payload/a16-ec-suspend-test.sh real
#
# probe  runs the whole suspend callback path WITHOUT powering down
#        (/sys/power/pm_test=devices). Zero risk of a frozen machine.
# real   an actual s2idle suspend/resume cycle.
#
# Both trace the driver's own functions with ftrace, so the evidence is the
# kernel's call record, not what the screen did.

set -u

TR=/sys/kernel/tracing
PAY=/home/jc/a16-payload
DIR="$PAY/asus-zenbook-a16-a14-ec-v3/evidence"
mkdir -p "$DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DIR/a16-ec-suspend-$STAMP.log"
MODE="${1:-}"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
die() { say ""; say "STOPPED: $*"; exit 1; }

stats() {
	local f
	for f in success fail failed_suspend failed_resume last_failed_dev last_failed_errno last_failed_step; do
		printf '  %-20s %s\n' "$f" "$(cat "/sys/power/suspend_stats/$f" 2>/dev/null)"
	done
}

ec_now() {
	local h=""
	for x in /sys/class/hwmon/hwmon*; do
		[ -r "$x/name" ] || continue
		[ "$(cat "$x/name" 2>/dev/null)" = asus_glymur_ec ] && h="$x"
	done
	if [ -z "$h" ]; then echo "  (asus_glymur_ec NOT present)" | tee -a "$LOG"; return; fi
	printf '  fan1 %s  fan2 %s  temp1 %s  temp2 %s\n' \
		"$(cat "$h/fan1_input")" "$(cat "$h/fan2_input")" \
		"$(cat "$h/temp1_input")" "$(cat "$h/temp2_input")" | tee -a "$LOG"
}

[ "$(id -u)" = 0 ] || die "this needs root:  sudo bash $0 {probe|real}"
[ -d "$TR" ] || die "no tracefs at $TR"
[ "$MODE" = probe ] || [ "$MODE" = real ] || die "usage: sudo bash $0 {probe|real}"

say "a16 EC suspend/resume proof"
say "date  : $(date)"
say "kernel: $(uname -r)"
say "mode  : $MODE"
say ""
say "=== the EC before ==="
ec_now
say ""
say "=== suspend stats before ==="
stats | tee -a "$LOG"

# ---------------------------------------------------------------- arm ftrace
say ""
say "=== arming ftrace on the driver's own functions ==="
echo 0 > "$TR/tracing_on" 2>/dev/null
echo > "$TR/trace" 2>/dev/null
echo function_graph > "$TR/current_tracer" 2>/dev/null
echo > "$TR/set_graph_function" 2>/dev/null
for f in asus_glymur_ec_suspend asus_glymur_ec_resume; do
	echo "$f" >> "$TR/set_graph_function" 2>/dev/null
done
arm_i2c=0
if [ -d "$TR/events/i2c/i2c_write" ]; then
	echo 1 > "$TR/events/i2c/i2c_write/enable" 2>/dev/null && arm_i2c=1
fi
echo 1 > "$TR/options/funcgraph-retval" 2>/dev/null
echo 1 > "$TR/tracing_on" 2>/dev/null
say "  function_graph on: asus_glymur_ec_suspend, asus_glymur_ec_resume"
say "  return values     : $([ -w "$TR/options/funcgraph-retval" ] && echo 'captured (funcgraph-retval)' || echo 'not capturable here')"
say "  i2c_write tracepoint: $([ "$arm_i2c" = 1 ] && echo enabled || echo 'not available')"
say "  (the trace buffer survives s2idle -- it lives in RAM)"

# ------------------------------------------------------------------- probe
if [ "$MODE" = probe ]; then
	say ""
	say "=== PROBE: running the suspend path without powering down ==="
	say "  /sys/power/pm_test = devices  -> the kernel runs every device's"
	say "  suspend and resume callback, pauses, then resumes itself."
	say "  The machine does not sleep. Nothing can freeze."
	say ""
	echo devices > /sys/power/pm_test || die "could not set pm_test"
	echo mem > /sys/power/state
	rc=$?
	echo none > /sys/power/pm_test
	say "  echo mem returned: $rc"
else
	say ""
	say "=== REAL: an actual s2idle suspend ==="
	say "  The machine will sleep now. Wake it with a key press or the"
	say "  power button. The screen going off and coming back is the least"
	say "  interesting part -- the trace below is the evidence."
	say ""
	say "  If it does not come back, hold the power button to force off."
	say ""
	sleep 3
	echo mem > /sys/power/state
	rc=$?
	say "  echo mem returned: $rc  (this line only prints after resume)"
fi

# ------------------------------------------------------------------ collect
echo 0 > "$TR/tracing_on" 2>/dev/null
say ""
say "=== suspend stats after ==="
stats | tee -a "$LOG"

say ""
say "=== THE EVIDENCE: what the driver actually did ==="
cp "$TR/trace" "$LOG.trace" 2>/dev/null
if grep -qE 'asus_glymur_ec_(suspend|resume)' "$LOG.trace" 2>/dev/null; then
	say "  -- the driver's callbacks, opening and closing lines --"
	grep -E 'asus_glymur_ec_(suspend|resume)' "$LOG.trace" | sed 's/^/    /' | tee -a "$LOG"
	say ""
	say "  -- every write the kernel made to the EC (bus i2c-9, addr 0x76) --"
	grep -oE 'i2c_write: i2c-9 #0 a=076 [^]]*\]' "$LOG.trace" | sort -u | sed 's/^/    /' | tee -a "$LOG"
	say ""
	say "  -- the suspend call in full, to its return --"
	sed -n '/asus_glymur_ec_suspend() {/,+34p' "$LOG.trace" | sed 's/^/    /' | tee -a "$LOG"
else
	say "  the driver's functions do NOT appear in the trace."
	say "  That means the callbacks were not called -- the PM core never"
	say "  reached the device. Send me this output."
fi

say ""
say "=== the whole trace buffer was saved to $LOG.trace ==="

say ""
say "=== the EC after ==="
ec_now

say ""
say "=== what these results mean ==="
say "  asus_glymur_ec_suspend in the trace, returning 0"
say "      -> the EC was told to enter standby, and it acked."
say "  asus_glymur_ec_resume in the trace, returning 0"
say "      -> the EC was told to exit standby, and it acked."
say "  a non-zero return, or the function missing"
say "      -> the notification did NOT work; send me the log."
say "  suspend_stats/success incremented, last_failed_dev empty"
say "      -> the kernel considers the cycle to have completed."
say ""
say "Log: $LOG"
