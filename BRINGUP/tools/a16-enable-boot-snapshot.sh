#!/usr/bin/env bash
# a16-enable-boot-snapshot.sh -- install a16-boot-snapshot.sh as a systemd oneshot that runs ~45 s
#                                into every boot and writes to the INTERNAL disk.
#
#   sudo bash a16-enable-boot-snapshot.sh            # install + enable (+ capture once now)
#   sudo bash a16-enable-boot-snapshot.sh --remove   # take it out again
#
# Why late, and why the internal disk: the older report unit runs ~1 s in, before any driver has
# probed, and its ESP sink silently loses writes on this machine (FAT + unset clock).  For a boot
# whose picture dies, the useful evidence is what msm/panel/dp did 10-40 s in, and it has to
# survive a power-cut.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SNAP="$HERE/a16-boot-snapshot.sh"
UNIT=/etc/systemd/system/a16-boot-snapshot.service
DEST=/usr/local/sbin/a16-boot-snapshot.sh
USER_HOME="$(getent passwd "${SUDO_USER:-jc}" | cut -d: -f6)"

say() { printf '%s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "needs root: sudo bash $0"; exit 1; }

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now a16-boot-snapshot.service 2>/dev/null
  rm -f "$UNIT" "$DEST"; systemctl daemon-reload
  say "removed $UNIT"
  exit 0
fi

[ -f "$SNAP" ] || { say "FATAL: $SNAP not found (run this from BRINGUP/tools/)"; exit 1; }
install -m 0755 "$SNAP" "$DEST" || { say "install failed"; exit 1; }
cat > "$UNIT" <<EOF
[Unit]
Description=A16 late boot snapshot (display/clock/regulator state) to the internal disk
Documentation=file://$USER_HOME/A16Build/BRINGUP/tools/a16-boot-snapshot.sh
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=no
# late enough that msm/panel/dp have probed (or failed), early enough to be there after a
# power-cycle of a black-screen boot
ExecStartPre=/bin/sleep 45
ExecStart=$DEST
Nice=10
TimeoutStartSec=240

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable a16-boot-snapshot.service 2>&1 | tail -2
say ""
say "installed: $DEST"
say "unit     : $UNIT  (runs 45 s after every boot, snapshots land in $USER_HOME/a16-payload/boots/)"
say ""
say "capturing one now (this boot)…"
A16_SNAP_DIR="$USER_HOME/a16-payload/boots" bash "$DEST" 2>&1 | tail -12
say ""
say "list snapshots later with:  bash $SNAP --list"
