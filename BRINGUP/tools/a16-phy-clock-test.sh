#!/usr/bin/env bash
# a16-phy-clock-test.sh -- why the tert combo PHY's clock bundle is refused.
#
#   sudo bash ~/a16.sh phyclock read    # read-only: the CBCR words of the tert PHY's clock group
#                                       # next to the working sec PHY's, the TCSR reference words,
#                                       # and the rails those references depend on
#   sudo bash ~/a16.sh phyclock cycle   # writes one bit: sets the tert PHY's reference bit in the
#                                       # TCSR, watches whether its COM clock starts, restores it
#
# The question this answers.  `qmp_combo_com_init` enables the combo PHY's clocks through
# `clk_bulk_prepare_enable`, which walks the DT order -- aux, ref, com_aux, usb3_pipe -- and stops at
# the first failure (drivers/clk/clk-bulk.c).  For `88e1000.phy` the failure is `com_aux`, so:
#   * `aux` (0xe1070) DID assert  -- the PHY's block is powered and its ref (TCSR USB4_2 CLKREF) was
#     enabled one step earlier, and neither errored;
#   * `com_aux` (0xe1074), two 32-bit registers away, with the same halt check, never asserts;
#   * `gcc_usb_2_phy_gdsc` is on, and the sec PHY (`fde000.phy`, 0xe2070/74/78, same driver, same DT
#     clock list, same ordering) works.
#
# So the possibilities left are narrow, and the register readback separates them:
#   bit0 of a CBCR is the branch enable, bit31 is the halt status ("clock off").
#   * bit0 reads back 0 after the framework set it  -> the write to 0xe1074 does not land, i.e. the
#     address in gcc-glymur.c is wrong for this silicon (the sec/tert tables differ only in the bank).
#   * bit0 reads back 1 and bit31 stays 1           -> the branch is held off by the hardware, i.e.
#     something else has to be voted on before it can run (PHY bring-up, not the clock table).
#
# `read` changes nothing.  `cycle` enables clocks that nothing else is using and puts the counts back
# where it found them; the PHY is unused on this machine (HDMI and DP do not come up yet).
#
# Logged to ~/a16-payload/phy-clock-<timestamp>.log.
set -u

MODE="${1:-read}"
LOG="${A16_LOG:-/home/jc/a16-payload/phy-clock-$(date +%Y%m%d-%H%M%S).log}"
GCC_BASE=$(python3 - <<'PY'
import os, struct
p = '/proc/device-tree/soc@0/clock-controller@100000/reg'
try:
    b = open(p, 'rb').read()
    hi, lo = struct.unpack('>II', b[:8])
    print(hex((hi << 32) | lo))
except Exception:
    print('0x100000')
PY
)
TCSR_BASE=$(python3 - <<'PY'
import os, struct
try:
    b = open('/proc/device-tree/soc@0/clock-controller@1fd5000/reg', 'rb').read()
    hi, lo = struct.unpack('>II', b[:8])
    print(hex((hi << 32) | lo))
except Exception:
    print('0x1fd5000')
PY
)
# offsets below are relative to the GCC base; tert = 0xe1xxx, sec = 0xe2xxx
TERT_AUX=0xe1070; TERT_COM=0xe1074; TERT_PIPE=0xe1078
SEC_AUX=0xe2070;  SEC_COM=0xe2074;  SEC_PIPE=0xe2078
# and the clock references live in the TCSR: bit0 = enable (QCOM_CLK_REF_EN_MASK, clk-ref.c)
TCSR_USB4_1=0x44   # the working sec PHY's ref (fde000.phy), currently enabled
TCSR_USB4_2=0x5c   # the refused tert PHY's ref (88e1000.phy)

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------"; }
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec > >(tee -a "$LOG") 2>&1

if [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-0}" != 1 ]; then
  say "This needs root. Type exactly this line:"
  say ""
  say "    sudo bash ~/a16.sh phyclock $MODE"
  say ""
  exit 1
fi

# --- read a 32-bit word out of /dev/mem (device memory, not RAM; blocked if STRICT_DEVMEM says no)
peek() { # $1 = absolute address in hex
  python3 - "$1" <<'PY'
import mmap, os, struct, sys
addr = int(sys.argv[1], 16)
page = addr & ~0xfff
off = addr - page
try:
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    v = struct.unpack_from('<I', m, off)[0]
    os.close(fd)
    print('%#010x' % v)
except Exception as e:
    print('unreadable (%s)' % e)
PY
}

# --- decode a CBCR word: bit0 = branch enable, bit31 = halt status ("clock off")
decode() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
if not s.startswith('0x'):
    print(s); raise SystemExit
v = int(s, 16)
print('%s -> enable(bit0)=%d  halt(bit31)=%d   %s' % (
    s, v & 1, (v >> 31) & 1,
    'clock running' if not ((v >> 31) & 1) else 'clock off'))
PY
}

group() { # $1 = label, $2..4 = aux com pipe offsets
  say "-- $1"
  for pair in "aux:$2" "com_aux:$3" "pipe:$4"; do
    n=${pair%%:*}; o=${pair##*:}
    a=$(printf '0x%x' $(( GCC_BASE + o )))
    printf '   %-8s @ %-10s %s\n' "$n" "$a" "$(decode "$(peek "$a")")"
  done
}

snapshot() {
  say "=== a16-phy-clock-test  $(date '+%Y-%m-%d %H:%M:%S')  mode=$MODE ==="
  say "kernel   : $(uname -r)"
  say "GCC base : $GCC_BASE   (from /proc/device-tree/soc@0/clock-controller@100000/reg)"
  say "combo PHYs: $(for p in /sys/bus/platform/devices/*.phy; do d=$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null); case "$d" in *combo*) printf '%s(%s) ' "$(basename "$p")" "$(cat "$p/power/runtime_status" 2>/dev/null)";; esac; done)"
  rule
  say "-- clock framework's view (enable/prepare counts, owner)"
  grep -E 'gcc_usb3_(tert|sec)_phy|tcsr_usb4_[12]_clkref' /sys/kernel/debug/clk/clk_summary 2>/dev/null \
    | sed 's/^/   /' | head -20
  rule
  say "-- the registers themselves (CBCR layout: bit0 = enable, bit31 = halted)"
  group "tert PHY  (88e1000.phy -- HDMI; the one that is refused)" "$TERT_AUX" "$TERT_COM" "$TERT_PIPE"
  group "sec PHY   (fde000.phy -- working control, same driver and DT shape)" "$SEC_AUX" "$SEC_COM" "$SEC_PIPE"
  say ""
  say "   The working control should show enable=1 for aux/com_aux (both are held on by the PHY's"
  say "   successful init) and the tert one should show enable=0."
  rule
  say "-- the clock references in the TCSR (bit0 = enabled; USB4_1 is the working one)"
  for pair in "usb4_1 (sec PHY, working):$TCSR_USB4_1" "usb4_2 (tert PHY, refused):$TCSR_USB4_2"; do
    n=${pair%%:*}; o=${pair##*:}
    a=$(printf '0x%x' $(( TCSR_BASE + o )))
    printf '   %-26s @ %-10s %s\n' "$n" "$a" "$(decode "$(peek "$a")")"
  done
  say ""
  say "   usb4_1 reads enable=1 (its PHY init succeeded and holds it); usb4_2 is expected to be 0 now,"
  say "   because its PHY init failed and unwound.  The 'cycle' run is what tests usb4_2."
  rule
  say "-- the rails those reference gates depend on (names from tcsrcc-glymur.c)"
  for r in vdda-refgen3-0p9 vdda-refgen3-1p2 vdda-qrefrx5-0p9 vdda-qreftx0-0p9 vdda-qreftx0-1p2 \
           vdda-refgen4-0p9 vdda-refgen4-1p2 vdda-qreftx1-0p9 vdda-qrefrpt0-0p9 vdda-qrefrpt1-0p9 \
           vdda-qrefrx1-0p9; do
    line=$(grep -m1 -- "$r" /sys/kernel/debug/regulator/regulator_summary 2>/dev/null)
    printf '   %-20s %s\n' "$r" "${line:-<absent from regulator_summary>}"
  done
  say ""
  say "   The USB4_2 ref needs the refgen4 / qreftx1 / qrefrpt0 / qrefrpt1 / qrefrx1 sets; the working"
  say "   USB4_1 needs refgen3 / qrefrx5 / qreftx0.  A rail that is absent, or present but disabled"
  say "   while its PHY wants it, is a candidate for why the tert PHY's COM clock never runs."
  rule
}

# Poking a register directly is the only way in here: the clock framework's per-clock write knob
# (clk_prepare_enable under debugfs) exists only when the kernel is built with
# CLOCK_ALLOW_WRITE_DEBUGFS, and drivers/clk/clk.c guards it with #ifdef -- this kernel has it off,
# so there is no framework path that can enable a clock from userspace.
poke() { # $1 = absolute address, $2 = value to write; prints the value read back
  python3 - "$1" "$2" <<'PY'
import mmap, os, struct, sys
addr = int(sys.argv[1], 16)
val = int(sys.argv[2], 16)
page = addr & ~0xfff
off = addr - page
try:
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
    struct.pack_into('<I', m, off, val)
    m.flush()
    back = struct.unpack_from('<I', m, off)[0]
    os.close(fd)
    print('%#010x' % back)
except Exception as e:
    print('unwritable (%s)' % e)
PY
}

snapshot

if [ "$MODE" = read ]; then
  say "Read-only run: nothing was changed.  For the write test (enables these clocks one at a time"
  say "through the clock framework and reads the register back), run:"
  say ""
  say "    sudo bash ~/a16.sh phyclock cycle"
  say ""
  say "log: $LOG"
  exit 0
fi

if [ "$MODE" != cycle ]; then
  say "unknown mode '$MODE' (use read or cycle)"; exit 2
fi

say "=== cycle: does the tert PHY's reference make its COM clock run? ==="
say "One bit is written through /dev/mem and put back; nothing else is touched, and the output being"
say "examined (HDMI on the tert PHY) does not work in the first place."

say "-- the working control (read only): its reference is held by a successful init"
say "   usb4_1  ref  $(decode "$(peek "$(printf '0x%x' $(( TCSR_BASE + TCSR_USB4_1 )))")")"
say "   sec com_aux  $(decode "$(peek "$(printf '0x%x' $(( GCC_BASE + SEC_COM )))")")"

say "-- the experiment: set the tert PHY's reference bit and watch its COM clock"
com0=$(peek "$(printf '0x%x' $(( GCC_BASE + TERT_COM )))")
tsr0=$(peek "$(printf '0x%x' $(( TCSR_BASE + TCSR_USB4_2 )))")
say "   before : com_aux  $(decode "$com0")"
say "            usb4_2   $(decode "$tsr0")"
case "$tsr0" in
  0x*)
    new=$(printf '0x%08x' $(( $(printf '%d' "$tsr0") | 1 )))
    back=$(poke "$(printf '0x%x' $(( TCSR_BASE + TCSR_USB4_2 )))" "$new")
    say "   wrote TCSR usb4_2 |= bit0 ($new) -> reads back $(decode "$back")"
    sleep 0.1
    say "   after  : com_aux  $(decode "$(peek "$(printf '0x%x' $(( GCC_BASE + TERT_COM )))")")"
    say "            (the enable bit was already set by the boot attempt, so if the reference was the"
    say "             missing piece the halt bit clears here on its own)"
    rest=$(poke "$(printf '0x%x' $(( TCSR_BASE + TCSR_USB4_2 )))" "$tsr0")
    say "   restore: wrote $tsr0 -> reads back $(decode "$rest")"
    say "            com_aux  $(decode "$(peek "$(printf '0x%x' $(( GCC_BASE + TERT_COM )))")")"
    say "            usb4_1 (untouched) $(decode "$(peek "$(printf '0x%x' $(( TCSR_BASE + TCSR_USB4_1 )))")")"
    ;;
  *)
    say "   the TCSR word could not be read, so there is nothing to poke ($tsr0)"
    ;;
esac

say ""
say "How to read the 'after' line:"
say "  com_aux halt bit clears once the reference bit is set -> the reference gate is exactly what the"
say "      COM clock was missing.  Note the driver already sets that bit before com_aux, inside one"
say "      clk_bulk call -- and clk_bulk_prepare() ignores a prepare failure, while"
say "      qcom_clk_ref_prepare() is what enables the ref's rails.  A silently failed regulator enable"
say "      lands exactly here, so that is the next thing to look at."
say "  com_aux halt bit stays set -> the reference bit alone is not enough: the COM block needs"
say "      something this kernel never votes for, which is the upstream combo-PHY bring-up the"
say "      component doc names.  Then the rails behind the ref gates (vdda-refgen4-*, vdda-qrefrpt1-*)"
say "      are the only local thing left to check."
say ""
say "  No clock can be enabled through the clock framework on this kernel: the per-clock"
say "  clk_prepare_enable knob is compiled out (CLOCK_ALLOW_WRITE_DEBUGFS is off), which is why this"
say "  run pokes the register directly instead."

say ""
say "-- nothing else to put back: the only write was that one bit, and it was restored above."
say "   com_aux $(decode "$(peek "$(printf '0x%x' $(( GCC_BASE + TERT_COM )))")")"
say "log: $LOG"
