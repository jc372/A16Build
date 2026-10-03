#!/usr/bin/env bash
# Reversible second-layer Glymur DP trial: ONLY replace the QMP v5 combo-PHY
# with the same driver plus PCS LN0/LN1 drive updates on training set_voltages.
# Keep the existing dpnext MSM guard/rate fix and its rollback state intact.
#   sudo bash ~/a16.sh dpdrive          stage for NEXT boot (no live reload)
#   bash ~/a16.sh dpdrive status|dry-run
#   sudo bash ~/a16.sh dpdrive revert   return to the previous QMP v5 layer
# Revert this layer before trying `dpnext revert` (initrd checksums are layered).
set -Eeuo pipefail
MODE="${1:-stage}"
RUNNING_KVER="$(uname -r)"
KVER="$RUNNING_KVER"
STATE_BASE=/var/lib/a16-dpdrive
if [ "$MODE" = revert ] && [ ! -f "$STATE_BASE/$KVER/state" ]; then
  states=("$STATE_BASE"/*/state)
  if [ "${#states[@]}" = 1 ] && [ -f "${states[0]}" ]; then
    KVER="${states[0]%/state}"; KVER="${KVER##*/}"
  elif [ "${#states[@]}" -gt 1 ]; then
    printf 'FATAL: multiple DP-drive rollback states; refusing to guess kernel\n' >&2
    exit 1
  fi
fi
CANDIDATE=/home/jc/build/linux-next-1a1de54f7369-qmp-v5-ln-drive/drivers/phy/qualcomm/phy-qcom-qmp-combo.ko
PREVIOUS=/home/jc/build/linux-next-1a1de54f7369-qmp-v5/drivers/phy/qualcomm/phy-qcom-qmp-combo.ko
DEST="/lib/modules/$KVER/updates/a16/phy-qcom-qmp-combo.ko"
INITRD="/boot/initrd.img-$KVER"
STATE="$STATE_BASE/$KVER"
UNDER_QMP="/var/lib/a16-qmpdp/$KVER"
UNDER_MSM="/var/lib/a16-dpnext/$KVER"
LOG="/home/jc/a16-payload/dpdrive-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
say() { printf '%s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
srcversion() { modinfo -F srcversion "$1" 2>/dev/null || true; }
resolved() { modinfo -k "$KVER" -F filename "$1" 2>/dev/null || true; }
crcs() { modprobe --dump-modversions "$1" | sort; }
say "=== dpdrive $(date '+%Y-%m-%d %H:%M:%S') mode=$MODE kernel=$KVER ==="
say "log: $LOG"

status() {
  say "current candidate: $CANDIDATE"
  if [ -f "$CANDIDATE" ]; then
    say "candidate srcversion=$(srcversion "$CANDIDATE") sha256=$(sha "$CANDIDATE")"
  else say 'candidate MISSING'; fi
  say "QMP resolver: $(resolved phy-qcom-qmp-combo)"
  if [ -f "$DEST" ]; then say "QMP installed srcversion=$(srcversion "$DEST") sha256=$(sha "$DEST")"; fi
  if [ -r /sys/module/phy_qcom_qmp_combo/srcversion ]; then
    say "QMP loaded srcversion=$(< /sys/module/phy_qcom_qmp_combo/srcversion)"
  fi
  if [ -r /sys/module/msm/srcversion ]; then say "MSM loaded srcversion=$(< /sys/module/msm/srcversion)"; fi
  if [ -d "$STATE" ]; then say "DP-drive rollback: present at $STATE (record root-only)";
  else say 'DP-drive rollback: none'; fi
  if [ -d "$UNDER_QMP" ] && [ -d "$UNDER_MSM" ]; then say 'underlying QMP and MSM rollback dirs: present';
  else say 'WARNING: an underlying rollback dir is missing'; fi
}

preflight() {
  local old_vm new_vm mismatch
  [ -f "$CANDIDATE" ] && [ -f "$PREVIOUS" ] && [ -f "$DEST" ] || {
    say 'FATAL: candidate, prior v5 module, or installed QMP override missing'; return 1;
  }
  [ -d "$UNDER_QMP" ] && [ -d "$UNDER_MSM" ] || {
    say 'FATAL: existing QMP and MSM rollback dirs required; refusing an unlayered trial'; return 1;
  }
  [ "$(resolved phy-qcom-qmp-combo)" = "$DEST" ] || {
    say 'FATAL: QMP module resolver does not select the expected override'; return 1;
  }
  [ "$(sha "$PREVIOUS")" = "$(sha "$DEST")" ] || {
    say 'FATAL: installed QMP differs from the known-working previous v5 trial'; return 1;
  }
  [ "$(srcversion "$CANDIDATE")" != "$(srcversion "$DEST")" ] || {
    say 'FATAL: no different QMP candidate to test'; return 1;
  }
  old_vm="$(modinfo -F vermagic "$DEST")"
  new_vm="$(modinfo -F vermagic "$CANDIDATE")"
  [ "$new_vm" = "$old_vm" ] && [[ "$new_vm" = "$KVER "* ]] || {
    say "FATAL: vermagic mismatch old='$old_vm' candidate='$new_vm'"; return 1;
  }
  mismatch="$(comm -3 <(crcs "$DEST") <(crcs "$CANDIDATE"))"
  [ -z "$mismatch" ] || { say 'FATAL: imported-symbol CRC mismatch'; say "$mismatch"; return 1; }
  say "candidate ABI: vermagic and $(crcs "$CANDIDATE" | wc -l | tr -d ' ') symbol CRCs match the loaded-version file"
  say "previous QMP: $(srcversion "$DEST") sha256=$(sha "$DEST")"
  say "new QMP:      $(srcversion "$CANDIDATE") sha256=$(sha "$CANDIDATE")"
}

remove_state() {
  rm -f "$STATE/state" "$STATE/previous.ko" "$STATE/initrd.before"
  rmdir "$STATE"
}

read_state() {
  prior_module_sha='' staged_module_sha='' prior_initrd_sha='' staged_initrd_sha=''
  [ -f "$STATE/state" ] || { say 'FATAL: DP-drive rollback record missing'; return 1; }
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
    say 'FATAL: DP-drive rollback backup missing or checksum mismatch'; return 1;
  }
}

restore() {
  local force="${1:-0}" actual_module actual_initrd
  read_state || return 1
  if [ "$force" != 1 ]; then
    actual_module="$(sha "$DEST")"
    actual_initrd="$(sha "$INITRD")"
    { [ "$actual_module" = "$staged_module_sha" ] || [ "$actual_module" = "$prior_module_sha" ]; } &&
    { [ "$actual_initrd" = "$staged_initrd_sha" ] || [ "$actual_initrd" = "$prior_initrd_sha" ]; } || {
      say 'FATAL: installed QMP or initrd changed since staging; refusing to overwrite'; return 1;
    }
  fi
  install -D -m 0644 "$STATE/previous.ko" "$DEST" || return 1
  depmod -a "$KVER" || return 1
  cp -a "$STATE/initrd.before" "$INITRD" || return 1
  [ "$(sha "$DEST")" = "$prior_module_sha" ] &&
  [ "$(sha "$INITRD")" = "$prior_initrd_sha" ] &&
  [ "$(resolved phy-qcom-qmp-combo)" = "$DEST" ] || {
    say "FATAL: rollback verification failed; state retained at $STATE"; return 1;
  }
  remove_state
  say 'REVERTED: previous QMP v5 module and byte-identical initrd restored.'
  say 'The loaded module remains unchanged until reboot. Underlying dpnext rollback is intact.'
}

stage() {
  local entries parent_initrd_sha=''
  [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dpdrive'; return 1; }
  [ ! -e "$STATE" ] || { say "FATAL: DP-drive state already exists at $STATE; use status/revert"; return 1; }
  preflight || return 1
  [ -f "$UNDER_QMP/state" ] && [ -f "$UNDER_MSM/state" ] || {
    say 'FATAL: root-only underlying rollback records missing'; return 1;
  }
  while IFS='=' read -r key value; do
    if [ "$key" = STAGED_INITRD_SHA ]; then parent_initrd_sha="$value"; fi
  done < "$UNDER_QMP/state"
  [ -n "$parent_initrd_sha" ] && [ -f "$INITRD" ] &&
  [ "$(sha "$INITRD")" = "$parent_initrd_sha" ] || {
    say 'FATAL: initrd differs from the underlying QMP staged state; refusing to layer changes';
    return 1;
  }
  [ -f /sys/module/phy_qcom_qmp_combo/srcversion ] &&
  [ "$(< /sys/module/phy_qcom_qmp_combo/srcversion)" = "$(srcversion "$DEST")" ] &&
  [ -f /sys/module/msm/srcversion ] &&
  [ "$(< /sys/module/msm/srcversion)" = "$(srcversion "/lib/modules/$KVER/updates/a16/msm.ko")" ] || {
    say 'FATAL: current boot did not load the staged base QMP/MSM modules'; return 1;
  }
  [ -f "$INITRD" ] && command -v lsinitramfs >/dev/null || {
    say 'FATAL: readable initrd and lsinitramfs required'; return 1;
  }
  entries="$(lsinitramfs "$INITRD")" || { say 'FATAL: cannot read initrd; no changes made'; return 1; }
  case "$entries" in *updates/a16/phy-qcom-qmp-combo.ko*) ;;
    *) say 'FATAL: initrd lacks the current QMP override; refusing to stage'; return 1 ;;
  esac
  mkdir -m 0700 -p "$STATE" || return 1
  cp -a "$DEST" "$STATE/previous.ko" || { remove_state; return 1; }
  cp -a "$INITRD" "$STATE/initrd.before" || { remove_state; return 1; }
  printf 'PRIOR_MODULE_SHA=%s\nSTAGED_MODULE_SHA=%s\nPRIOR_INITRD_SHA=%s\nSTAGED_INITRD_SHA=%s\n' \
    "$(sha "$DEST")" "$(sha "$CANDIDATE")" "$(sha "$INITRD")" "$(sha "$INITRD")" > "$STATE/state"
  chmod 0600 "$STATE/state" || return 1

  say "Installing only the new QMP module at $DEST (no live reload)."
  install -D -m 0644 "$CANDIDATE" "$DEST" || { say 'Install failed; restoring'; restore 1; return 1; }
  depmod -a "$KVER" || { say 'depmod failed; restoring'; restore 1; return 1; }
  update-initramfs -u -k "$KVER" || { say 'initrd update failed; restoring'; restore 1; return 1; }
  entries="$(lsinitramfs "$INITRD")" || { say 'initrd unreadable; restoring'; restore 1; return 1; }
  case "$entries" in *updates/a16/phy-qcom-qmp-combo.ko*) ;;
    *) say 'FATAL: final initrd lacks QMP override; restoring'; restore 1; return 1 ;;
  esac
  printf 'STAGED_INITRD_SHA=%s\n' "$(sha "$INITRD")" >> "$STATE/state"
  [ "$(sha "$DEST")" = "$(sha "$CANDIDATE")" ] &&
  [ "$(resolved phy-qcom-qmp-combo)" = "$DEST" ] || {
    say 'FATAL: installed QMP bytes/resolver mismatch; restoring'; restore 1; return 1;
  }
  say "VERIFIED: new QMP sha256=$(sha "$DEST") and initrd entry updated; rollback at $STATE"
  say 'STAGED FOR NEXT BOOT. Current loaded modules remain the previous trial.'
  say 'Keep USB-C monitor unplugged. Next: sudo reboot, verify dpdrive status, start display watch dp, connect once.'
  say 'If it fails: sudo bash ~/a16.sh dpdrive revert ; reboot.'
  say 'To restore stock later: dpdrive revert FIRST, then dpnext revert (separate commands).'
}

case "$MODE" in
  status) status ;;
  dry-run) preflight; status; say 'DRY RUN: initrd/root rollback records are checked only by stage; no changes made.' ;;
  stage) stage ;;
  revert)
    [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dpdrive revert'; exit 1; }
    [ -f "$STATE/state" ] || { say "No DP-drive rollback record for $KVER; nothing changed."; exit 0; }
    restore ;;
  *) say 'usage: sudo bash ~/a16.sh dpdrive [stage|revert|status|dry-run]'; exit 2 ;;
esac
say "log: $LOG"
