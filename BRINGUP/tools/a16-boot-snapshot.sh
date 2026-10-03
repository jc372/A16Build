#!/usr/bin/env bash
# a16-boot-snapshot.sh -- write the state needed to explain a boot that had no picture (or any
#                         boot worth keeping), to the INTERNAL disk, once per boot.
#
#   sudo bash a16-boot-snapshot.sh            # capture now
#   bash a16-boot-snapshot.sh --list          # what is there
#   A16_SNAP_DIR=/somewhere sudo bash a16-boot-snapshot.sh
#
# Why this exists next to a16-boot-report.sh: that one runs ~1 s in (so it misses every driver
# probe) and writes to the ESP, whose FAT has silently dropped writes -- the [4] and [3] display
# boots produced no usable report at all.  This one runs *late* (the unit sleeps 45 s) and writes
# to ext4 under the operator's home, where a power-cut cannot lose it.  Name the directory by
# boot id, and identify it by content: the clock is unset early in the boot, so directory names
# carry a bogus date (this machine has no readable RTC until chronyd syncs).
set -u

if [ "${1:-}" = "--list" ]; then
  for d in "${A16_SNAP_DIR:-/home/jc/a16-payload/boots}"/*/ ; do
    [ -d "$d" ] || continue
    printf '%s\n   %s\n' "$(basename "$d")" "$(head -1 "$d/00-identity.txt" 2>/dev/null | cut -c1-140)"
  done
  exit 0
fi

# Where the operator's home is.  Under systemd there is no HOME and no SUDO_USER, so a bare $HOME
# crashed the unit ("HOME: unbound variable", exit 1, no snapshot from the very boot we needed one
# for).  Resolve it explicitly instead: SUDO_USER, else HOME, else the account that owns the payload.
PAYLOAD_USER="${A16_RESULT_USER:-jc}"
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
elif [ -n "${HOME:-}" ]; then
  USER_HOME="$HOME"
else
  USER_HOME="$(getent passwd "$PAYLOAD_USER" | cut -d: -f6)"
fi
[ -n "${USER_HOME:-}" ] || USER_HOME=/home/$PAYLOAD_USER
ROOT="${A16_SNAP_DIR:-$USER_HOME/a16-payload/boots}"
BOOTID="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
D="$ROOT/$(date +%Y%m%d-%H%M%S)-$BOOTID"
mkdir -p "$D" || { echo "cannot create $D"; exit 1; }

sum() { { echo "### $*"; bash -c "$*" 2>&1; echo; } >> "$D/99-summary.txt"; }
cap() { local f="$1"; shift; { echo "### \$ $*"; "$@" 2>&1; echo "### exit: $?"; } > "$D/$f" 2>&1 || true; }
caps() { local f="$1"; shift; { echo "### \$ $*"; bash -c "$*" 2>&1; echo "### exit: $?"; } > "$D/$f" 2>&1 || true; }

# mount debugfs if it is not there (clk/regulator/gpio/pinctrl state lives in it)
mountpoint -q /sys/kernel/debug 2>/dev/null || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

{
  echo "boot id   : $BOOTID"
  echo "snapshot  : $(date)   uptime: $(uptime -s) ($(cut -d' ' -f1 /proc/uptime)s)"
  echo "cmdline   : $(cat /proc/cmdline)"
  echo "kernel    : $(uname -r)   model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  echo "cmdline DT: $(tr ' ' '\n' < /proc/cmdline | grep -E 'module_blacklist|acpi=off|devicetree' | tr '\n' ' ')"
} > "$D/00-identity.txt"

caps 01-modules.txt      'lsmod | sort'
caps 02-drm.txt          'for c in /sys/class/drm/card*/; do echo "$(basename $c): driver=$(basename $(readlink -f $c/device/driver 2>/dev/null)) status=$(cat $c/status 2>/dev/null) modes=$(cat $c/modes 2>/dev/null | tr "\n" " ")"; done; echo "--- backlight:"; ls /sys/class/backlight/ 2>/dev/null || echo "(none)"; echo "--- fb:"; cat /proc/fb'
caps 03-deferred.txt     'cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "(none/not readable)"'
caps 04-dmesg-display.txt 'dmesg | grep -iE "msm|mdss|dpu|edp|panel|dispcc|videocc|gpucc|adreno|aperture|simpledrm|drm|smmu|com_aux|stuck|deferred|phys|phy-" | head -120'
caps 05-clk-display.txt  'grep -iE "dispcc|edp|dp_|mdp|mdss|vco|pll|pixel" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -80'
caps 06-clk-summary.txt  'head -60 /sys/kernel/debug/clk/clk_summary 2>/dev/null'
caps 07-regulators.txt   'grep -iE "VREG_EDP|VREG_WCN|regulator-edp|regulator-bt|edp" /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -30'
caps 08-gpio-display.txt 'grep -iE "gpio-(5|6|7)[0-9][0-9]|gpio-18|gpio-70|panel|bl-en|edp|backlight" /sys/kernel/debug/gpio 2>/dev/null | head -30'
caps 09-pinctrl-edp.txt  'for p in 18 70; do grep -m1 -E "^pin $p " /sys/kernel/debug/pinctrl/f100000.pinctrl/pinmux-pins; done 2>/dev/null'
caps 10-dmesg.txt        'dmesg'
[ -r /var/log/journal ] || true
caps 11-journal-kernel.txt 'journalctl -k -b 0 --no-pager | tail -400'
caps 12-power.txt        'upower -i /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat 2>/dev/null | grep -E "state|percentage|energy-full|time to"'

{
  echo "=== snapshot of boot $BOOTID ==="
  echo "cmdline: $(cat /proc/cmdline)"
  echo
  echo "-- DRM --";        cat "$D/02-drm.txt"
  echo
  echo "-- deferred --";   cat "$D/03-deferred.txt"
  echo
  echo "-- display --";    cat "$D/04-dmesg-display.txt"
  echo
  echo "-- panel rail --"; cat "$D/07-regulators.txt"
  echo
  echo "-- panel pins --"; cat "$D/09-pinctrl-edp.txt"
} > "$D/99-summary.txt"

chmod -R a+rX "$ROOT" 2>/dev/null || true

# best-effort copy to the ESP, so the other OS can read it -- never trusted, never required
ESP="${A16_ESP:-/boot/efi}"
if [ -d "$ESP/a16-reports" ] || mkdir -p "$ESP/a16-reports" 2>/dev/null; then
  if cp -a "$D" "$ESP/a16-reports/$(basename "$D")" 2>/dev/null; then
    echo "[a16-boot-snapshot] ESP copy: $ESP/a16-reports/$(basename "$D")"
  else
    echo "[a16-boot-snapshot] ESP copy failed (the ESP's FAT has dropped writes before -- ignore)"
  fi
fi

if [ -f "$D/99-summary.txt" ]; then
  echo "[a16-boot-snapshot] OK: $D ($(du -sh "$D" | cut -f1), $(ls "$D" | wc -l) files)"
  echo "[a16-boot-snapshot] summary:"
  sed 's/^/    /' "$D/99-summary.txt" | head -30
else
  echo "[a16-boot-snapshot] FAILED to write a summary in $D"
  exit 1
fi
