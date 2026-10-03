#!/usr/bin/env bash
# a16-enable-boot-report.sh -- install a16-boot-report.sh as a systemd oneshot
# unit on the installed system and run it once, so every boot (ACPI or
# devicetree) leaves a report on the ESP.
#
#     sudo bash /home/jc/a16-payload/a16-enable-boot-report.sh
#
# Idempotent: re-running refreshes the script and the unit and re-enables them.
# Remove with:  sudo systemctl disable --now a16-boot-report.service
set -u

SRC="/home/jc/a16-payload/a16-boot-report.sh"
TARGET="/usr/local/sbin/a16-boot-report.sh"
UNIT="/etc/systemd/system/a16-boot-report.service"
LOG="/boot/efi/A16REPORT-SETUP.LOG"

say() { echo "[a16-report-setup] $*" | tee -a "$LOG" 2>/dev/null; }

if [ "$(id -u)" != "0" ]; then
  echo "[a16-report-setup] needs root. Re-run as:"
  echo "    sudo bash $0"
  exit 1
fi

touch "$LOG" 2>/dev/null || LOG=/var/tmp/A16REPORT-SETUP.LOG
say "=== a16-enable-boot-report $(date 2>/dev/null) ==="
[ -f "$SRC" ] || { say "missing $SRC -- aborting"; exit 1; }

install -m 0755 "$SRC" "$TARGET" && say "installed $TARGET" || { say "install of $TARGET failed"; exit 1; }

cat > "$UNIT" <<'UNIT'
[Unit]
Description=A16 boot report (display/input/clock state) to the ESP
Documentation=file:///home/jc/a16-payload/a16-boot-report.sh
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/sbin/a16-boot-report.sh
TimeoutStartSec=300
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
say "wrote $UNIT"

systemctl daemon-reload && say "daemon-reload ok" || say "daemon-reload failed"
systemctl enable a16-boot-report.service 2>&1 | sed 's/^/[a16-report-setup] /' | tee -a "$LOG"
say "running it once now (baseline for this boot)"
"$TARGET" 2>&1 | sed 's/^/[a16-report-setup] /' | tee -a "$LOG"
say "status:"
systemctl --no-pager status a16-boot-report.service 2>&1 | head -12 | sed 's/^/[a16-report-setup] /' | tee -a "$LOG"
say "reports so far:"
ls -1dt /boot/efi/a16-reports/*/ 2>/dev/null | head -5 | sed 's/^/[a16-report-setup] /' | tee -a "$LOG"
say "=== done ==="
