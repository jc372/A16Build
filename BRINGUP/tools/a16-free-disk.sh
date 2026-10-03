#!/usr/bin/env bash
# a16-free-disk.sh -- reclaim space by deleting SUPERSEDED A16 kernel module sets.
#
#   bash a16-free-disk.sh --dry-run     # show what would go (default)
#   sudo bash a16-free-disk.sh --apply   # delete, then report
#
# Each linux-next module set costs ~7.5G, so superseded ones are where the space is.
# NEVER touched: the running kernel, the newest build (-xh1), the [3] fallback
# (7.3.0-rc3-next-20260914), and the distro kernels (-generic).
#
# This does not run `make clean` anywhere: the working tree is left exactly as it is.
set -u
MODE="${1:---dry-run}"
RUN="$(uname -r)"
# Keep: the running kernel, the [3] fallback, the distro kernels, and anything written in the
# last 30 minutes (an install that is still copying -- deleting that mid-flight is how you
# end up with a half-populated module set).
KEEP_RE="^(${RUN}|7\.3\.0-rc3-next-20260914|.*-generic.*)$"
KEEP_FRESH_SECS=1800

if [ "$MODE" = "--apply" ] && [ "$(id -u)" != 0 ]; then
  echo "FATAL: --apply needs root:  sudo bash $0 --apply"; exit 1
fi

printf '=== disk before ===\n'
df -h / | tail -1 | sed 's/^/  /'

printf '\n=== module sets ===\n'
cands=()
for d in /lib/modules/*/; do
  n=$(basename "$d"); s=$(du -sh "$d" 2>/dev/null | cut -f1)
  if [[ "$n" =~ $KEEP_RE ]]; then
    printf '  KEEP      %-42s %s (protected)\n' "$n" "$s"
  elif [ -n "$(find "/lib/modules/$n" -maxdepth 0 -newermt "-${KEEP_FRESH_SECS} seconds" 2>/dev/null)" ]; then
    printf '  KEEP      %-42s %s (installed <${KEEP_FRESH_SECS}s ago -- possibly in flight)\n' "$n" "$s"
  else
    printf '  REMOVE    %-42s %s\n' "$n" "$s"
    cands+=("$n")
  fi
done

if [ "${#cands[@]}" -eq 0 ]; then echo; echo "  nothing to remove"; exit 0; fi

printf '\n=== /boot files for those sets ===\n'
boots=()
for n in "${cands[@]}"; do
  for f in "/boot/vmlinuz-$n" "/boot/initrd.img-$n" "/boot/glymur-a16-stock-$n.dtb" \
           "/boot/glymur-$n.dtb" "/boot/glymur-a16-$n.dtb"; do
    [ -e "$f" ] && { printf '  REMOVE    %-52s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"; boots+=("$f"); }
  done
done

printf '\n=== orphaned DTBs (kernel already gone) ===\n'
# Protect the tree's own DT and the BT test DT: the installer may still read these, and
# they are 160K each, so sweeping them saves nothing worth the risk of breaking an install.
PROTECT_RE='^(glymur-asus-zenbook-a16-ux3607oa|glymur-a16-bt-test)\.dtb$'
orph=()
for d in /boot/glymur-*.dtb; do
  [ -e "$d" ] || continue
  [[ "$(basename "$d")" =~ $PROTECT_RE ]] && { printf '  KEEP      %-52s (installer input)\n' "$(basename "$d")"; continue; }
  v=$(basename "$d" | sed 's/^glymur-a16-stock-//; s/^glymur-a16-//; s/^glymur-//; s/\.dtb$//')
  if [ ! -f "/boot/vmlinuz-$v" ]; then
    printf '  REMOVE    %-52s %s\n' "$(basename "$d")" "$(du -h "$d" | cut -f1)"
    orph+=("$d")
  fi
done

if [ "$MODE" != "--apply" ]; then
  printf '\n  dry run. apply with:  sudo bash %s --apply\n' "$0"
  printf '  (each module set is ~7.5G, so this frees roughly %s sets worth)\n' "${#cands[@]}"
  exit 0
fi

printf '\n=== removing ===\n'
for n in "${cands[@]}"; do rm -rf "/lib/modules/$n" && printf '  removed /lib/modules/%s\n' "$n"; done
for f in "${boots[@]}"; do rm -f "$f" && printf '  removed %s\n' "$f"; done
for f in "${orph[@]}"; do rm -f "$f" && printf '  removed %s\n' "$f"; done

printf '\n=== disk after ===\n'
df -h / | tail -1 | sed 's/^/  /'
printf '\n  Note: grub entries pointing at these kernels were pruned separately\n'
printf '  (a16-grub-prune.sh). No initramfs rebuild is needed for removed sets.\n'
