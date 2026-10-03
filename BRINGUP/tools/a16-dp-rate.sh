#!/usr/bin/env bash
# Reversible third-layer DP trial: replace ONLY msm.ko with the external-DP
# link-rate-cap candidate (module parameter a16_dp_max_rate, written at runtime),
# layered over the currently installed dpnext MSM+QMP trial.  Nothing else
# (QMP combo-PHY, GRUB, DT) is touched.
#   sudo bash ~/a16.sh dprate            stage for NEXT boot (no live reload)
#   bash ~/a16.sh dprate status|dry-run
#   sudo bash ~/a16.sh dprate revert     return to the dpnext MSM layer
# Staging also installs /etc/modprobe.d/a16-msm-dp-rate.conf so the cap survives a
# reboot (the initrd rebuild is what delivers it to the early module load); revert
# removes that file before restoring the previous initrd image.
# Revert this layer before `dpnext revert` (layered initrd backups).
set -Eeuo pipefail
MODE="${1:-stage}"
RUNNING_KVER="$(uname -r)"
KVER="$RUNNING_KVER"
STATE_BASE=/var/lib/a16-dprate
if [ "$MODE" = revert ] && [ ! -f "$STATE_BASE/$KVER/state" ]; then
  states=("$STATE_BASE"/*/state)
  if [ "${#states[@]}" = 1 ] && [ -f "${states[0]}" ]; then
    KVER="${states[0]%/state}"; KVER="${KVER##*/}"
  elif [ "${#states[@]}" -gt 1 ]; then
    printf 'FATAL: multiple MSM-DPRATE rollback states; refusing to guess kernel\n' >&2
    exit 1
  fi
fi
CANDIDATE=/home/jc/build/linux-next-1a1de54f7369-dprate/drivers/gpu/drm/msm/msm.ko
PARENT_MSM=/home/jc/build/linux-next-1a1de54f7369/drivers/gpu/drm/msm/msm.ko
DEST="/lib/modules/$KVER/updates/a16/msm.ko"
INITRD="/boot/initrd.img-$KVER"
STATE="$STATE_BASE/$KVER"
PARENT="/var/lib/a16-dpnext/$KVER"
LOG="/home/jc/a16-payload/dprate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
say() { printf '%s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
srcversion() { modinfo -F srcversion "$1" 2>/dev/null || true; }
resolved() { modinfo -k "$KVER" -F filename "$1" 2>/dev/null || true; }
crcs() { modprobe --dump-modversions "$1" | sort; }
live_srcversion() { cat "/sys/module/$1/srcversion" 2>/dev/null || true; }
say "=== dprate $(date '+%Y-%m-%d %H:%M:%S') mode=$MODE kernel=$KVER ==="
say "log: $LOG"

status() {
  say "candidate: $CANDIDATE"
  if [ -f "$CANDIDATE" ]; then
    say "  srcversion=$(srcversion "$CANDIDATE") sha256=$(sha "$CANDIDATE")"
  else say '  MISSING'; fi
  say "MSM resolver: $(resolved msm)"
  [ -f "$DEST" ] && say "MSM installed: srcversion=$(srcversion "$DEST") sha256=$(sha "$DEST")"
  say "MSM loaded: $(live_srcversion msm)"
  say "QMP loaded (untouched by this layer): $(live_srcversion phy_qcom_qmp_combo)"
  if [ -d "$STATE" ]; then say "MSM-DPRATE rollback: present at $STATE (record root-only)";
  else say 'MSM-DPRATE rollback: none'; fi
  if [ -d "$PARENT" ]; then say 'underlying dpnext MSM/QMP rollback: present';
  else say 'WARNING: underlying dpnext rollback dir is missing'; fi
}

preflight() {
  local old_vm new_vm mismatch parent_initrd_sha=''
  [ -f "$CANDIDATE" ] && [ -f "$PARENT_MSM" ] && [ -f "$DEST" ] || {
    say 'FATAL: candidate, dpnext MSM, or installed msm.ko missing'; return 1;
  }
  [ -d "$PARENT" ] || {
    say 'FATAL: dpnext rollback directory required; refusing an unlayered trial'; return 1;
  }
  [ "$(resolved msm)" = "$DEST" ] || {
    say 'FATAL: msm module resolver does not select the expected override'; return 1;
  }
  [ "$(sha "$PARENT_MSM")" = "$(sha "$DEST")" ] || {
    say 'FATAL: installed msm.ko differs from the known dpnext MSM layer'; return 1;
  }
  [ "$(srcversion "$CANDIDATE")" != "$(srcversion "$DEST")" ] || {
    say 'FATAL: no different MSM candidate to test'; return 1;
  }
  old_vm="$(modinfo -F vermagic "$DEST")"
  new_vm="$(modinfo -F vermagic "$CANDIDATE")"
  [ "$new_vm" = "$old_vm" ] && [[ "$new_vm" = "$KVER "* ]] || {
    say "FATAL: vermagic mismatch old='$old_vm' candidate='$new_vm'"; return 1;
  }
  # the candidate may ADD imports, but every symbol the reference module set
  # already imported must still be there with an unchanged CRC
  mismatch="$(comm -23 <(crcs "$DEST") <(crcs "$CANDIDATE"))"
  [ -z "$mismatch" ] || {
    say 'FATAL: candidate changes or drops imported symbol CRCs:'; say "$mismatch"; return 1;
  }
  say "candidate ABI: vermagic identical, $(crcs "$DEST" | wc -l | tr -d ' ') shared symbol CRCs match, $(comm -13 <(crcs "$DEST") <(crcs "$CANDIDATE") | wc -l | tr -d ' ') new imports"
  say "previous MSM: $(srcversion "$DEST") sha256=$(sha "$DEST")"
  say "new MSM:      $(srcversion "$CANDIDATE") sha256=$(sha "$CANDIDATE")"
}

read_state() {
  prior_module_sha='' staged_module_sha='' prior_initrd_sha='' staged_initrd_sha=''
  [ -f "$STATE/state" ] || { say 'FATAL: MSM-DPRATE rollback record missing'; return 1; }
  while IFS='=' read -r key value; do
    case "$key" in
      PRIOR_MODULE_SHA) prior_module_sha="$value" ;;
      STAGED_MODULE_SHA) staged_module_sha="$value" ;;
      PRIOR_INITRD_SHA) prior_initrd_sha="$value" ;;
      STAGED_INITRD_SHA) staged_initrd_sha="$value" ;;
    esac
  done < "$STATE/state"
  [ -n "$prior_module_sha" ] && [ -n "$staged_module_sha" ] &&
  [ -n "$prior_initrd_sha" ] && [ -n "$staged_initrd_sha" ] &&
  [ -f "$STATE/previous.ko" ] && [ -f "$STATE/initrd.before" ] &&
  [ "$(sha "$STATE/previous.ko")" = "$prior_module_sha" ] &&
  [ "$(sha "$STATE/initrd.before")" = "$prior_initrd_sha" ] || {
    say 'FATAL: MSM-DPRATE rollback backup missing or checksum mismatch'; return 1;
  }
}

remove_state() {
  rm -f "$STATE/state" "$STATE/previous.ko" "$STATE/initrd.before"
  rmdir "$STATE"
}

restore() {
  local force="${1:-0}" actual_module actual_initrd
  read_state || return 1
  if [ "$force" != 1 ]; then
    actual_module="$(sha "$DEST")"
    actual_initrd="$(sha "$INITRD")"
    { [ "$actual_module" = "$staged_module_sha" ] || [ "$actual_module" = "$prior_module_sha" ]; } &&
    { [ "$actual_initrd" = "$staged_initrd_sha" ] || [ "$actual_initrd" = "$prior_initrd_sha" ]; } || {
      say 'FATAL: installed msm.ko or initrd changed since staging; refusing to overwrite'; return 1;
    }
  fi
  install -D -m 0644 "$STATE/previous.ko" "$DEST" || return 1
  depmod -a "$KVER" || return 1
  cp -a "$STATE/initrd.before" "$INITRD" || return 1
  [ "$(sha "$DEST")" = "$prior_module_sha" ] &&
  [ "$(sha "$INITRD")" = "$prior_initrd_sha" ] &&
  [ "$(resolved msm)" = "$DEST" ] || {
    say "FATAL: rollback verification failed; state retained at $STATE"; return 1;
  }
  remove_state
  say 'REVERTED: dpnext MSM layer and byte-identical initrd restored.'
  say 'The loaded module remains unchanged until reboot. Underlying dpnext rollback is intact.'
}

stage() {
  local entries current_initrd layer state_initrd matched=''
  [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dprate'; return 1; }
  [ ! -e "$STATE" ] || { say "FATAL: MSM-DPRATE state already exists at $STATE; use status/revert"; return 1; }
  preflight || return 1

  # The dpnext staging recorded the initrd before its own QMP layer
  # regenerated it, so accept the initrd if it matches ANY currently staged
  # layer's record (innermost first).  Matching none means the initramfs was
  # regenerated behind our back, and layering must not proceed.
  [ -f "$INITRD" ] || { say 'FATAL: readable initrd required'; return 1; }
  current_initrd="$(sha "$INITRD")"
  for layer in "/var/lib/a16-qmpdp/$KVER" "$PARENT"; do
    [ -f "$layer/state" ] || {
      say "FATAL: cannot read the staged-layer record under $layer; refusing"; return 1;
    }
    state_initrd="$(sed -n 's/^STAGED_INITRD_SHA=//p' "$layer/state" | tail -1)"
    if [ -n "$state_initrd" ] && [ "$state_initrd" = "$current_initrd" ]; then
      matched="$layer"
      break
    fi
  done
  [ -n "$matched" ] || {
    say "FATAL: initrd sha256=$current_initrd matches no staged-layer record; refusing to layer changes";
    return 1;
  }
  say "current initrd matches the staged-layer record of $matched"

  [ "$(live_srcversion msm)" = "$(srcversion "$DEST")" ] &&
  [ "$(live_srcversion phy_qcom_qmp_combo)" = "$(srcversion /lib/modules/$KVER/updates/a16/phy-qcom-qmp-combo.ko)" ] || {
    say 'FATAL: current boot did not load the expected dpnext MSM/QMP modules'; return 1;
  }
  command -v lsinitramfs >/dev/null || { say 'FATAL: lsinitramfs required'; return 1; }
  entries="$(lsinitramfs "$INITRD")" || { say 'FATAL: cannot read initrd; no changes made'; return 1; }
  case "$entries" in *updates/a16/msm.ko*) ;;
    *) say 'FATAL: initrd lacks the current MSM override; refusing to stage'; return 1 ;;
  esac
  case "$entries" in *updates/a16/phy-qcom-qmp-combo.ko*) ;;
    *) say 'FATAL: initrd lacks the QMP override; refusing to stage'; return 1 ;;
  esac
  mkdir -m 0700 -p "$STATE" || return 1
  cp -a "$DEST" "$STATE/previous.ko" || { remove_state; return 1; }
  cp -a "$INITRD" "$STATE/initrd.before" || { remove_state; return 1; }
  printf 'PRIOR_MODULE_SHA=%s\nSTAGED_MODULE_SHA=%s\nPRIOR_INITRD_SHA=%s\nSTAGED_INITRD_SHA=%s\n' \
    "$(sha "$DEST")" "$(sha "$CANDIDATE")" "$(sha "$INITRD")" "$(sha "$INITRD")" > "$STATE/state"
  chmod 0600 "$STATE/state" || return 1

  say "Installing only the new msm.ko at $DEST (no live reload)."
  install -D -m 0644 "$CANDIDATE" "$DEST" || { say 'Install failed; restoring'; restore 1; return 1; }
  depmod -a "$KVER" || { say 'depmod failed; restoring'; restore 1; return 1; }
  say 'Installing /etc/modprobe.d/a16-msm-dp-rate.conf so the rate cap survives reboots.'
  mkdir -p /etc/modprobe.d
  printf 'options msm a16_dp_max_rate=540000\n' > /etc/modprobe.d/a16-msm-dp-rate.conf || { say 'writing the module option failed; restoring'; restore 1; return 1; }
  update-initramfs -u -k "$KVER" || { say 'initrd update failed; restoring'; restore 1; return 1; }
  entries="$(lsinitramfs "$INITRD")" || { say 'initrd unreadable; restoring'; restore 1; return 1; }
  case "$entries" in *updates/a16/msm.ko*) ;;
    *) say 'FATAL: final initrd lacks MSM override; restoring'; restore 1; return 1 ;;
  esac
  printf 'STAGED_INITRD_SHA=%s\n' "$(sha "$INITRD")" >> "$STATE/state"
  [ "$(sha "$DEST")" = "$(sha "$CANDIDATE")" ] &&
  [ "$(resolved msm)" = "$DEST" ] || {
    say 'FATAL: installed msm.ko bytes/resolver mismatch; restoring'; restore 1; return 1;
  }
  say "VERIFIED: new msm.ko sha256=$(sha "$DEST") and initrd entry updated; rollback at $STATE"
  say 'STAGED FOR NEXT BOOT. Current loaded modules remain the previous trial.'
  say 'Keep USB-C monitor unplugged. Next: sudo reboot, then check loaded srcversion, then start display watch dp, then connect once.'
  say 'If it fails: sudo bash ~/a16.sh dprate revert ; reboot.'
  say 'To restore stock later: dprate revert FIRST, then dpnext revert (separate commands).'
}

case "$MODE" in
  status) status ;;
  dry-run) preflight; status; say 'DRY RUN: initrd/root rollback records are checked only by stage; no changes made.' ;;
  stage) stage ;;
  revert)
    [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dprate revert'; exit 1; }
    [ -f "$STATE/state" ] || { say "No MSM-DPRATE rollback record for $KVER; nothing changed."; exit 0; }
    if [ -f /etc/modprobe.d/a16-msm-dp-rate.conf ]; then
      rm -f /etc/modprobe.d/a16-msm-dp-rate.conf
      say 'Removed the persistent a16_dp_max_rate option; the initrd restore below drops it from the image.'
    fi
    restore ;;
  *) say 'usage: sudo bash ~/a16.sh dprate [stage|revert|status|dry-run]'; exit 2 ;;
esac
say "log: $LOG"
