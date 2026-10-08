#!/usr/bin/env bash
# a16-backup.sh -- replicate this working machine somewhere else, so it can be rebuilt.
#
#   bash a16-backup.sh plan   <dest> [essential|full]     # sizes, free space, what would go -- writes nothing
#   bash a16-backup.sh run    <dest> [essential|full]     # copy for real (long: run it in the background)
#   bash a16-backup.sh verify <dest> [essential|full]     # compare what landed with what is here
#
# Why this exists: everything that makes this machine reproducible lives in a handful of places that
# are NOT covered anywhere else -- the notes/tools/logs in ~, my own configuration/sessions/skills in
# ~/.hermes, the handful of system files we edited, /lib/modules + /boot as actually installed, and a
# kernel tree that carries local source edits and is *not* a git checkout (those edits exist nowhere
# else; the pinned tarball alone will not rebuild this kernel).
#
# PROFILES
#   essential and full are now the SAME scope by policy: copy what cannot be re-obtained.  The
#   operator's rule is no redownloadables, so Downloads, Steam, /opt (Chrome), caches, virtualenvs,
#   npm and the agent's own software payloads are skipped.  What goes: ~ minus those (~/Videos and
#   the snap/firefox profile DO go -- that is data, not software), ~/a16-payload, ~/A16Build,
#   ~/.config, ~/.local, the system files we changed, /boot, /lib/modules/<ver>, the ESP bits, and
#   the kernel source tree (which carries local edits and is not a git checkout).
# NEVER copied (regenerable): kernel build objects in ~/build/*/, snap/steam, shadercache, caches,
# Trash, .hermes/{tools,hermes-agent,installs}, Downloads, .npm, .venv.  `plan` prints exact numbers.
#
# ORDER MATTERS: run `sudo bash ~/a16.sh backup-root` FIRST, then this.  The root pass drops a
# tarball into ~/a16-payload, and anything written into the home while a copy is running is missed
# ("file changed as we read it") -- which is what happened on 2026-10-07 when the two overlapped.
#
# TRANSPORT is chosen by the destination, because it matters:
#   local filesystem -> rsync -aHAX (metadata preserved, re-runnable)
#   gvfs/SMB mount   -> tar streams (one archive per area).  A home directory is ~10^5 small files and
#                       SMB pays per file; tarring turns that into a handful of big sequential writes.
set -u

MODE=${1:-plan}
DEST=${2:-}
PROFILE=${3:-essential}
[ -n "$DEST" ] || { printf 'usage: bash %s plan|run|verify <dest-dir> [essential|full]\n' "$0"; exit 2; }
case "$PROFILE" in essential|full) ;; *) printf 'profile must be essential or full\n'; exit 2 ;; esac

VER=$(uname -r)
LOG_DIR=/home/jc/a16-payload
STAMP=$(date +%Y%m%d-%H%M%S)

say() { printf '%s\n' "$*"; }

# --- is the destination remote-ish (gvfs/SMB) or a real filesystem? -------------------------------
case "$DEST" in
  /run/user/*/gvfs/*|smb:*|/run/media/*/*) ;;
esac
REMOTE=no
case "$DEST" in
  /run/user/*/gvfs/*) REMOTE=yes ;;
esac

# --- what to copy: area|srcdir|per-area excludes -------------------------------------------------
areas() {
  say "/home/jc|home/jc"
  say "/home/jc/build/next-20261002-repull|kernel-src/next-20261002-repull"
  say "/etc|system/etc"
  say "/usr/local|system/usr-local"
  say "/boot|system/boot"
  say "/lib/modules/$VER|system/lib-modules/$VER"
  say "/boot/efi/EFI/ubuntu|esp/EFI/ubuntu"
  say "/boot/efi/EFI/ubuntu_snapdragon|esp/EFI/ubuntu_snapdragon"
  say "/boot/efi/EFI/Boot|esp/EFI/Boot"
}

# Exclusions are per source root, so that e.g. "*.ko" can drop build objects in ~/build without
# dropping the installed modules we are deliberately keeping.
#
# Policy (the operator's rule): copy what cannot be re-obtained, skip everything that can be
# downloaded or rebuilt.  So no Downloads, no Steam, no /opt (Chrome), no caches, no virtualenvs,
# no npm cache, no agent payloads -- and therefore `essential` and `full` now mean the same thing.
excludes_for() {
  case "$1" in
    /home/jc)
      say '.cache/'
      say '.local/share/Trash/'
      say 'Downloads/'
      say '.npm/'
      say '.venv/'
      say 'build/'
      say 'snap/steam/'
      say '.local/share/Steam/'
      say '.hermes/cache/'
      say '.hermes/tools/'
      say '.hermes/hermes-agent/'
      say '.hermes/installs/'
      ;;
    /home/jc/build/next-20261002-repull)
      # source tree WITH the local edits, without the build products.  The edits are the point:
      # this tree is not a git checkout, so they exist nowhere else.
      for p in '*.o' '*.ko' '*.cmd' '*.a' '*.dwo' '.tmp_*' 'vmlinux' 'vmlinux.o' 'Image' 'Image.gz' \
               'System.map' '*.dtb' '*.dtbo' '*.mod' '*.mod.c' '*.su' '*.symtypes' '*.lst' '*.tmp'; do
        say "$p"
      done
      ;;
    *) : ;;
  esac
}

size_of() {  # $1 = source root, $2 = destination root.  Exact bytes rsync would copy, via a dry run:
             # `du --exclude` matches basenames, not paths, so it silently ignored every pattern above.
  local root=$1 dest=$2 ex=() total
  if [ "$REMOTE" = yes ]; then
    total=$(du -sb "$root" 2>/dev/null | awk '{print $1}')          # upper bound; NAS has room
  else
    while read -r e; do ex+=(--exclude="$e"); done < <(excludes_for "$root")
    if [ -d "$root" ]; then
      total=$(rsync -aHAX -n --stats "${ex[@]}" "$root/" "$dest/" 2>/dev/null \
              | awk '/Total file size/{gsub(/,/,"");print $4}')
    else
      total=$(rsync -aHAX -n --stats "$root" "$dest" 2>/dev/null \
              | awk '/Total file size/{gsub(/,/,"");print $4}')
    fi
  fi
  printf '%s' "${total:-0}"
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%s bytes' "${1:-0}"; }

plan() {
  local grand=0
  say "-- source sizes (before exclusions decision: what actually gets copied)"
  while IFS='|' read -r src rel; do
    [ -d "$src" ] || [ -f "$src" ] || { say "   $rel: absent, skipped"; continue; }
    local b; b=$(size_of "$src" "$DEST/$rel")
    grand=$((grand + b))
    printf '   %-34s %10s   %s\n' "$rel" "$(human "$b")" "$src"
  done < <(areas)
  say ""
  say "-- total to copy: $(human "$grand")  (profile: $PROFILE)"
  say "-- destination: $DEST"
  if [ -d "$DEST" ]; then
    df -h "$DEST" 2>/dev/null | tail -1 | sed 's/^/   /'
    local avail; avail=$(df -PB1 "$DEST" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "${avail:-}" ] && [ "$avail" -lt "$grand" ]; then
      say "   !! destination has $(human "$avail") free -- NOT enough.  Use the other target or the full/NAS profile."
    fi
  else
    say "   (destination does not exist yet)"
  fi
  [ "$REMOTE" = yes ] && say "   transport: tar streams (gvfs/SMB)" || say "   transport: rsync -aHAX"
}

run() {
  [ -d "$DEST" ] || { say "destination $DEST does not exist"; exit 1; }
  touch "$DEST/.a16-write-test" 2>/dev/null || { say "destination is not writable"; exit 1; }
  rm -f "$DEST/.a16-write-test"
  # Refuse to start if the destination cannot hold what we are about to copy: this runs unattended.
  if [ "$REMOTE" != yes ]; then
    local need=0 avail
    while IFS='|' read -r src rel; do
      [ -d "$src" ] || [ -f "$src" ] || continue
      need=$(( need + $(size_of "$src" "$DEST/$rel") ))
    done < <(areas)
    avail=$(df -PB1 "$DEST" 2>/dev/null | tail -1 | awk '{print $4}')
    say "-- needs $(human "$need"), destination has $(human "${avail:-0}") free"
    if [ -n "${avail:-}" ] && [ "$avail" -lt "$need" ] && [ "${A16_BACKUP_FORCE:-0}" != 1 ]; then
      say "!! not enough room -- refusing to start.  Free space, pick another destination, or set A16_BACKUP_FORCE=1."
      exit 4
    fi
  fi
  local log="$LOG_DIR/backup-$(basename "$DEST" | tr -c 'A-Za-z0-9._-' '_')-$STAMP.log"
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$log") 2>&1
  say "# a16-backup.sh run  $(date -Is)  profile=$PROFILE  dest=$DEST"
  say "# log: $log"
  local rc=0
  while IFS='|' read -r src rel; do
    [ -d "$src" ] || [ -f "$src" ] || continue
    local out="$DEST/$rel"
    mkdir -p "$(dirname "$out")" 2>/dev/null
    if [ "$REMOTE" = yes ]; then
      local ex=(); while read -r e; do ex+=(--exclude="$e"); done < <(excludes_for "$src")
      say "-- tar $src -> $out.tar   $(date +%H:%M:%S)"
      # -b 2048 = 1 MiB records: over gvfs/SMB the default 10 KiB records cost ~1.6 MB/s, 1 MiB gets ~34.
      tar -b 2048 -cf - "${ex[@]}" -C "$(dirname "$src")" "$(basename "$src")" > "$out.tar" \
        || { say "   FAILED rc=$?"; rc=1; }
      ls -lh "$out.tar" 2>/dev/null | awk '{print "   ", $5, $NF}'
    else
      say "-- rsync $src -> $out   $(date +%H:%M:%S)"
      local ex=(); while read -r e; do ex+=(--exclude="$e"); done < <(excludes_for "$src")
      if [ -d "$src" ]; then
        rsync -aHAX --info=stats2 --human-readable "${ex[@]}" "$src/" "$out/" || { say "   FAILED rc=$?"; rc=1; }
      else
        rsync -aHAX --info=stats2 --human-readable "$src" "$out" || { say "   FAILED rc=$?"; rc=1; }
      fi
    fi
  done < <(areas)
  manifest
  say "# done $(date -Is)  rc=$rc"
  return $rc
}

manifest() {
  local f="$DEST/MANIFEST.txt"
  {
    say "# a16 rebuild manifest -- written $(date -Is) by a16-backup.sh"
    say "# profile: $PROFILE   host: $(hostname)   kernel: $(uname -a)"
    say "# areas copied (source -> subdir under here):"
    areas | sed 's/^/#   /'
    say "# exclusions applied per root:"
    while IFS='|' read -r src rel; do while read -r e; do say "#   $src  exclude $e"; done < <(excludes_for "$src"); done < <(areas)
    say ""
    say "## how to rebuild (sketch)"
    say "#  1. base install: Ubuntu 26.04 arm64, user jc, ESP mounted at /boot/efi"
    say "#  2. system files:   rsync -aHAX system/etc/ /etc/ ; system/usr-local/ -> /usr/local/"
    say "#  3. kernel:         install system/boot/* and system/lib-modules/$VER/ (drop into /boot, /lib/modules)"
    say "#                     sources with the local edits are in the kernel tree copy (see areas above)"
    say "#  4. ESP:            copy esp/ back over /boot/efi/ (grub.cfg x3 copies + the DTBs live in /boot)"
    say "#  5. the workspace:  home/jc -> ~jc  (notes, tools, logs, and ~/.hermes = the agent itself)"
    say "#  6. packages:       dpkg --set-selections < packages.selections ; apt-get dselect-upgrade"
    say ""
    say "## packages installed (manual list)"
    apt-mark showmanual 2>/dev/null | sed 's/^/  /'
    say ""
    say "## dpkg selections (restore with: dpkg --set-selections < packages.selections)"
    dpkg --get-selections 2>/dev/null | sed 's/^/  /'
    say ""
    say "## kernels / initrds / DTBs present"
    ls -la /boot 2>/dev/null | sed 's/^/  /'
    say ""
    say "## modules we built and installed"
    find "/lib/modules/$VER" -name '*.ko*' -newermt '2026-09-01' -printf '  %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | head -40
    say ""
    say "## loaded modules at backup time"
    lsmod 2>/dev/null | sed 's/^/  /'
  } > "$f" 2>&1
  cp -f "$f" "$DEST/packages.selections" 2>/dev/null || true
  say "-- manifest written: $f"
}

verify() {
  local bad=0
  while IFS='|' read -r src rel; do
    [ -d "$src" ] || continue
    local here there
    here=$(find "$src" -type f 2>/dev/null | wc -l)
    if [ "$REMOTE" = yes ]; then
      say "   $rel: $here files here; archive $(ls -lh "$DEST/$rel.tar" 2>/dev/null | awk '{print $5}') there"
      [ -s "$DEST/$rel.tar" ] || { say "   !! missing or empty archive"; bad=1; }
    else
      there=$(find "$DEST/$rel" -type f 2>/dev/null | wc -l)
      printf '   %-34s here=%-8s there=%-8s %s\n' "$rel" "$here" "$there" "$([ "$there" -ge "$here" ] && echo ok || echo '!! fewer')"
      [ "$there" -ge "$here" ] || bad=1
    fi
  done < <(areas)
  [ "$bad" = 0 ] && say "-- verify: everything present" || say "-- verify: differences above"
  return $bad
}

case "$MODE" in
  plan)   plan ;;
  run)    run ;;
  verify) verify ;;
  *)      say "usage: bash $0 plan|run|verify <dest-dir> [essential|full]"; exit 2 ;;
esac
