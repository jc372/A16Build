#!/usr/bin/env bash
# a16-backup-root.sh -- collect the files the user-mode backup cannot read, so the backup is faithful.
#
#   sudo bash ~/a16.sh backup-root
#
# A user session cannot read /etc/shadow, /etc/gshadow, /etc/sudoers, /etc/ufw/*.rules, the /boot
# initrds or /boot/grub/grub.cfg -- nor the files your own root-run scripts dropped into
# ~/a16-payload (perf-game.data, ec test traces, a stashed initrd).  So a backup taken as jc is
# missing them.  This bundles exactly those files into one tarball and puts a copy beside each
# backup destination, which is enough to restore them (tar -xf into /).
set -u

DEST_LOCAL=${A16_DEST_LOCAL:-/run/media/jc/7c816d1a-b4c1-4e8e-b9d9-c439844dda78/A16-backup-20261007}
DEST_NAS=${A16_DEST_NAS:-/run/user/1000/gvfs/smb-share:server=catesserver.local,share=homes/jc/a16-backup-20261007}

if [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-0}" != 1 ]; then
  printf 'This needs root.  Type exactly:\n\n    sudo bash ~/a16.sh backup-root\n\n'
  exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=/home/jc/a16-payload/root-only-$STAMP.tar
LIST=$(mktemp)
say() { printf '%s\n' "$*"; }

# everything under /etc and /boot that has no world-read bit, plus root-owned files inside the home
{ find /etc /boot -type f ! -perm -004 2>/dev/null
  find /home/jc/a16-payload -type f -user root 2>/dev/null
} | sort -u > "$LIST"

say "-- files only root can read: $(wc -l < "$LIST")"
tar -cf "$OUT" -T "$LIST" 2>/dev/null || true
chown jc:jc "$OUT" 2>/dev/null || true
chmod 644 "$OUT" 2>/dev/null || true
say "-- $OUT  ($(du -h "$OUT" 2>/dev/null | cut -f1))"

for d in "$DEST_LOCAL" "$DEST_NAS"; do
  [ -d "$d" ] || { say "   skip (absent): $d"; continue; }
  case "$d" in
    /run/user/*/gvfs/*)
      # a per-user gvfs mount: root cannot write through it, so copy as jc
      if runuser -u jc -- cp -f "$OUT" "$d/" 2>/dev/null; then say "   copied to $d       (as jc)"; 
      else say "   NAS copy failed -- later run:  cp $OUT \"$d/\""; fi ;;
    *)
      if cp -f "$OUT" "$d/" 2>/dev/null; then say "   copied to $d"; 
      else say "   copy failed to $d"; fi ;;
  esac
done

rm -f "$LIST"
say ""
say "-- contents (first 30, restore with: sudo tar -xf <file> -C /)"
tar -tf "$OUT" 2>/dev/null | head -30 | sed 's/^/   /'
