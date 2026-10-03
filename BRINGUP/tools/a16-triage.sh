#!/usr/bin/env bash
# a16-triage.sh — collect everything we need off the A16 while it is running Linux.
#
# Usage (on the A16, in the installed Ubuntu/Tumbleweed session):
#   sudo bash /media/$USER/<STICK>/a16-triage.sh [TARGET_DIR]
#
# TARGET_DIR defaults to the script's own directory (the USB stick) if writable,
# else /var/tmp. Prints the tarball path at the end.
#
# Design rules (from the arm64-laptop-bringup workflow):
#   * never fail hard - no `set -e`, every step guarded
#   * capture stdout AND stderr AND exit codes for probes that can lie
#   * print the reason a probe was skipped
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$SELF_DIR}"
mkdir -p "$TARGET" 2>/dev/null || TARGET=/var/tmp
if ! touch "$TARGET/.a16-write-test" 2>/dev/null; then
  echo "NOTE: $TARGET is not writable, falling back to /var/tmp"
  TARGET=/var/tmp
else
  rm -f "$TARGET/.a16-write-test"
fi

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/a16-triage-XXXXXX")"
mkdir -p "$WORK/data"

say() { echo "[a16-triage] $*"; }
capture() { # capture <outfile> <cmd...>
  local out="$1"; shift
  { echo "### \$ $*"; "$@" 2>&1; echo "### exit: $?"; } > "$WORK/data/$out" 2>&1 || true
}
capture_shell() { # capture_shell <outfile> <shell string>
  local out="$1"; shift
  { echo "### \$ $*"; bash -c "$*" 2>&1; echo "### exit: $?"; } > "$WORK/data/$out" 2>&1 || true
}

say "target: $TARGET   work: $WORK   uid=$(id -u)"
[ "$(id -u)" = 0 ] || say "WARNING: not root - /proc/iomem, efivars and some /sys reads will be incomplete"

# ---- identity -------------------------------------------------------------
capture uname.txt          uname -a
capture cmdline.txt        cat /proc/cmdline
capture os-release.txt     cat /etc/os-release
capture hostnamectl.txt    hostnamectl
capture dmi.txt            bash -c 'for f in /sys/class/dmi/id/*; do [ -r "$f" ] && echo "$f: $(cat "$f")"; done'
capture uptime.txt         uptime
capture date.txt           bash -c 'date; date -u; timedatectl'
capture lsblk.txt          lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,MODEL
capture df.txt             df -hT

# ---- memory map (authority for DT /memory ranges) -------------------------
capture iomem.txt          cat /proc/iomem
capture meminfo.txt        cat /proc/meminfo
capture efimemmap.txt      cat /sys/firmware/efi/memmap 2>/dev/null

# ---- firmware / EFI runtime (the open efivars question) -------------------
capture_shell efi-dir.txt     'ls -la /sys/firmware/efi/'
capture_shell efivars.txt     'ls -la /sys/firmware/efi/efivars/ | head -50; echo "count: $(ls /sys/firmware/efi/efivars/ 2>/dev/null | wc -l)"'
capture efibootmgr.txt     efibootmgr -v
capture_shell efibootmgr-which.txt 'command -v efibootmgr || echo "efibootmgr NOT INSTALLED (apt install efibootmgr)"'
capture_shell efi-tables.txt  'ls -la /sys/firmware/efi/esrt /sys/firmware/efi/runtime-map 2>&1'
capture_shell rtc.txt         'dmesg 2>/dev/null | grep -iE "rtc|acpi-tad|hctosys" | tail -30'

# ---- kernel / modules -----------------------------------------------------
capture dmesg.txt          bash -c 'dmesg'
capture dmesg-err.txt      bash -c 'dmesg -l err,warn'
capture journal-err.txt    journalctl -b -p err --no-pager
capture lsmod.txt          lsmod
capture modules-dir.txt    bash -c 'ls /lib/modules; for d in /lib/modules/*; do echo "== $d"; ls "$d" ; done'
capture_shell module-symbols.txt 'modprobe -n -v ath12k 2>&1; echo "---"; ls /lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/ath12k/ 2>&1'
capture kernelconfig.txt   bash -c 'zcat /proc/config.gz 2>/dev/null || cat /boot/config-$(uname -r) 2>/dev/null || echo "no kernel config available"'

# ---- PCI / USB ------------------------------------------------------------
capture lspci.txt          lspci -nnnk
capture lsusb.txt          lsusb -t
capture usb-devices.txt    bash -c 'for d in /sys/bus/usb/devices/*/; do [ -r "$d/product" ] && echo "$d $(cat $d/product 2>/dev/null) $(cat $d/idVendor 2>/dev/null):$(cat $d/idProduct 2>/dev/null)"; done'

# ---- input (the thing that does not work) ---------------------------------
capture input-devices.txt  cat /proc/bus/input/devices
capture_shell hid-sysfs.txt   'ls -la /sys/bus/hid/devices/ 2>&1; ls -la /sys/bus/i2c/devices/ 2>&1; for f in /sys/bus/i2c/devices/*/name; do echo "$f: $(cat $f 2>/dev/null)"; done'
capture_shell acpi-input.txt  'dmesg | grep -iE "i2c|QCOM0F10|QCOM0F0C|hid|asus|elan|goodix" | tail -60'
capture_shell acpi-devices.txt 'ls /sys/bus/acpi/devices/ ; echo ---; for d in /sys/bus/acpi/devices/*/; do echo "$(basename $d) status=$(cat $d/status 2>/dev/null) $(cat $d/hid 2>/dev/null)"; done'
capture_shell gpio-i2c-drivers.txt 'ls /sys/bus/platform/drivers/ | grep -iE "geni|i2c|gpio|spmi|qup|hid" ; echo ---; ls /sys/bus/i2c/drivers/ 2>&1'

# ---- display --------------------------------------------------------------
capture_shell drm.txt         'ls -la /sys/class/drm/; for c in /sys/class/drm/card*/status; do echo "$c: $(cat $c 2>/dev/null)"; done'
capture_shell drm-modes.txt   'cat /sys/class/drm/card*/modes 2>/dev/null | head -20'
capture_shell msm.txt         'dmesg | grep -iE "msm|drm|adreno|panel|edp|simpledrm|efifb" | tail -60'
capture_shell gpu-info.txt    'bash -c "command -v glxinfo >/dev/null && glxinfo -B 2>&1 | head -30 || echo no-glxinfo"'

# ---- network --------------------------------------------------------------
capture_shell net-links.txt   'ip -details link show; echo ---; ip addr; echo ---; ip route; echo ---; rfkill list; echo ---; nmcli device status 2>&1'
capture_shell ath12k.txt      'dmesg | grep -iE "ath12k|wcn7850|qcc2072|ath1|firmware" | tail -60'
capture_shell ath-pci.txt     'echo "--- 17cb devices:"; lspci -nn | grep -i 17cb; echo "--- driver bound to each:"; for b in $(lspci -nn | grep -i 17cb | cut -d" " -f1); do echo "== $b"; lspci -nnk -s "$b"; done; echo "--- modinfo ath12k:"; modinfo ath12k 2>&1 | head -10'
capture_shell ath-firmware.txt 'for d in /lib/firmware/ath12k/QCC2072/hw1.0 /lib/firmware/ath12k/WCN7850/hw2.0; do echo "== $d"; ls -la "$d" 2>&1; done; echo "--- all ath12k firmware:"; ls -laR /lib/firmware/ath12k 2>&1 | head -60; echo "--- version files:"; find /lib/firmware/ath12k -name "*version*" -exec sh -c "echo {}; cat {}" \; 2>/dev/null'
capture_shell qcom-firmware.txt 'ls -la /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/ 2>&1; ls -la /lib/firmware/qcom/ 2>&1 | head -30'
capture_shell firmware-search.txt 'for f in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf soccp.mbn soccp_dtb.mbn; do printf "%-24s " "$f"; ls /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/$f 2>/dev/null || echo MISSING; done'

# ---- other hardware -------------------------------------------------------
capture_shell audio.txt       'dmesg | grep -iE "sound|snd|audio|sof|q6" | tail -40; ls /sys/bus/platform/drivers/ | grep -iE "snd|q6"'
capture_shell bluetooth.txt   'dmesg | grep -iE "bluetooth|btqca|hci" | tail -20'
capture_shell thermal-battery.txt 'ls /sys/class/power_supply/ 2>&1; for d in /sys/class/power_supply/*/; do echo "== $d"; cat $d/type $d/status 2>/dev/null; done; sensors 2>&1 | head -20'
capture_shell nvme.txt        'dmesg | grep -iE "nvme|ufs|mmc" | tail -30'
capture_shell tpm-crypto.txt  'ls /dev/tpm* 2>&1; dmesg | grep -iE "tpm|crypto|qcrypto" | tail -20'

# ---- what an agent will want to read first -------------------------------
cat > "$WORK/SUMMARY.txt" <<EOF
a16-triage summary
host:        $(uname -n)  $(uname -r)
os:          $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
collected:   $(date -u) UTC  (local: $(date))
uid:         $(id -u)
cmdline:     $(cat /proc/cmdline)
--- quick answers ---
efivars:     $(ls /sys/firmware/efi/efivars/ 2>/dev/null | wc -l) entries, dir $([ -d /sys/firmware/efi/efivars ] && echo present || echo MISSING)
efibootmgr:  $(command -v efibootmgr || echo not-installed)
input:       $(grep -c '^N:' /proc/bus/input/devices 2>/dev/null || echo 0) input nodes; $( (ls /sys/bus/i2c/devices/ 2>/dev/null | wc -l) ) i2c devices
wifi:        $( (ls /lib/firmware/ath12k/QCC2072/hw1.0/ 2>/dev/null | wc -l) ) QCC2072/hw1.0 fw files, $( (ls /lib/firmware/ath12k/WCN7850/hw2.0/ 2>/dev/null | wc -l) ) WCN7850/hw2.0; 17cb PCI devices: $(lspci -nn 2>/dev/null | grep -ci 17cb); link state: $(for l in /sys/class/net/*/operstate; do echo -n "$(basename $(dirname $l))=$(cat $l) "; done)
drm:         $(for c in /sys/class/drm/card*/status; do [ -e "$c" ] && echo -n "$(basename $(dirname $c))=$(cat $c) "; done)
meminfo:     $(grep MemTotal /proc/meminfo)
EOF

# ---- pack -----------------------------------------------------------------
TARBALL="$TARGET/a16-triage-$(uname -n)-$STAMP.tar.gz"
tar -czf "$TARBALL" -C "$WORK" . 2>/dev/null && say "wrote $TARBALL ($(du -h "$TARBALL" | cut -f1))" || say "FAILED to write $TARBALL"
say "contents: $(tar -tzf "$TARBALL" 2>/dev/null | wc -l) files"
say "keep the stick in the A16, or copy this file off it from Windows before rebooting."
