#!/usr/bin/env bash
# A16 external-DP next-step trial: stage the repaired msm DP driver and the
# already-built Glymur QMP PHY together, retaining both prior modules/initrd.
# Type: sudo bash ~/a16.sh dpnext [stage|revert] ; bash ~/a16.sh dpnext status|dry-run
# Never swaps live modules and never connects a display by itself.
set -Eeuo pipefail
MODE="${1:-stage}"
RUNNING_KVER="$(uname -r)"
KVER="$RUNNING_KVER"
if [ "$MODE" = revert ] && [ ! -f "/var/lib/a16-dpnext/$KVER/state" ]; then
  states=(/var/lib/a16-dpnext/*/state)
  if [ "${#states[@]}" = 1 ] && [ -f "${states[0]}" ]; then
    KVER="${states[0]%/state}"
    KVER="${KVER##*/}"
  elif [ "${#states[@]}" -gt 1 ]; then
    printf 'FATAL: multiple DP-next rollback states; refusing to guess kernel\n' >&2
    exit 1
  fi
fi
BASE=/home/jc/A16Build/BRINGUP/tools
QMP_HELPER="$BASE/a16-qmpdp-module.sh"
QMP_STATE="/var/lib/a16-qmpdp/$KVER/state"
MSM_KO=/home/jc/build/linux-next-1a1de54f7369/drivers/gpu/drm/msm/msm.ko
MSM_DEST="/lib/modules/$KVER/updates/a16/msm.ko"
INITRD="/boot/initrd.img-$KVER"
STATE="/var/lib/a16-dpnext/$KVER"
LOG="/home/jc/a16-payload/dpnext-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
say() { printf '%s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
srcversion() { modinfo -F srcversion "$1" 2>/dev/null || true; }
resolved() { modinfo -k "$KVER" -F filename "$1" 2>/dev/null || true; }
crcs() { modprobe --dump-modversions "$1" | sort; }
say "=== dpnext $(date '+%Y-%m-%d %H:%M:%S') mode=$MODE kernel=$KVER ==="
say "log: $LOG"

show_status() {
  say "MSM candidate: $MSM_KO"
  if [ -f "$MSM_KO" ]; then say "  srcversion=$(srcversion "$MSM_KO") sha256=$(sha "$MSM_KO")"; fi
  say "MSM resolver: $(resolved msm)"
  if [ -f /sys/module/msm/srcversion ]; then say "MSM loaded srcversion: $(< /sys/module/msm/srcversion)"; fi
  if [ -d "$STATE" ]; then
    say "MSM trial state: present at $STATE (record root-only)"
  else
    say 'MSM trial state: none'
  fi
  say "QMP resolver: $(resolved phy-qcom-qmp-combo)"
  if [ -f /sys/module/phy_qcom_qmp_combo/srcversion ]; then
    say "QMP loaded srcversion: $(< /sys/module/phy_qcom_qmp_combo/srcversion)"
  fi
  if [ -d "${QMP_STATE%/state}" ]; then
    say "QMP trial state: present at ${QMP_STATE%/state} (record root-only)"
  else
    say 'QMP trial state: none'
  fi
}

preflight() {
  local old_vm new_vm mismatch
  [ -f "$MSM_KO" ] || { say "FATAL: MSM candidate missing: $MSM_KO"; return 1; }
  [ -f "$MSM_DEST" ] || { say "FATAL: previous MSM override missing: $MSM_DEST"; return 1; }
  [ -f "$QMP_HELPER" ] || { say 'FATAL: QMP staging helper missing'; return 1; }
  [ "$(resolved msm)" = "$MSM_DEST" ] || { say 'FATAL: unexpected MSM resolver; do not overwrite it'; return 1; }
  old_vm="$(modinfo -F vermagic "$MSM_DEST")"
  new_vm="$(modinfo -F vermagic "$MSM_KO")"
  [ "$new_vm" = "$old_vm" ] && [[ "$new_vm" = "$KVER "* ]] || {
    say "FATAL: MSM vermagic mismatch: old=$old_vm new=$new_vm"; return 1;
  }
  mismatch="$(comm -3 <(crcs "$MSM_DEST") <(crcs "$MSM_KO"))"
  [ -z "$mismatch" ] || { say 'FATAL: MSM imported-symbol CRC mismatch'; say "$mismatch"; return 1; }
  [ "$(sha "$MSM_DEST")" != "$(sha "$MSM_KO")" ] || {
    say 'FATAL: candidate is identical to current module; no test to stage'; return 1;
  }
  say "MSM ABI: vermagic and $(crcs "$MSM_KO" | wc -l) imported CRCs match installed module"
  say "MSM candidate: srcversion=$(srcversion "$MSM_KO") sha256=$(sha "$MSM_KO")"
  say 'QMP ABI is verified independently by the qmpdp helper during staging.'
}

read_state() {
  had_override='' has_initrd='' staged_initrd_sha='' staged_msm_sha='' prior_msm_sha='' prior_initrd_sha=''
  [ -f "$STATE/state" ] || { say 'No MSM staging record; refusing to guess rollback.'; return 1; }
  while IFS='=' read -r key value; do
    case "$key" in
      HAD_OVERRIDE) had_override="$value" ;;
      HAS_INITRD) has_initrd="$value" ;;
      STAGED_INITRD_SHA) staged_initrd_sha="$value" ;;
      STAGED_MSM_SHA) staged_msm_sha="$value" ;;
      PRIOR_MSM_SHA) prior_msm_sha="$value" ;;
      PRIOR_INITRD_SHA) prior_initrd_sha="$value" ;;
    esac
  done < "$STATE/state"
  case "$had_override:$has_initrd" in 0:0|0:1|1:0|1:1) ;; *) say 'FATAL: malformed MSM rollback state'; return 1 ;; esac
  [ -n "$staged_msm_sha" ] || { say 'FATAL: staged MSM checksum missing'; return 1; }
  [ "$had_override" = 0 ] || { [ -f "$STATE/msm.before" ] && [ "$(sha "$STATE/msm.before")" = "$prior_msm_sha" ]; } || {
    say 'FATAL: previous MSM module backup missing/mismatched'; return 1;
  }
  if [ "$has_initrd" = 1 ]; then
    [ -f "$STATE/initrd.before" ] && [ "$(sha "$STATE/initrd.before")" = "$prior_initrd_sha" ] &&
    [ -n "$staged_initrd_sha" ] || { say 'FATAL: initrd rollback state missing/mismatched'; return 1; }
  fi
}

restore_msm() {
  local force="${1:-0}"
  read_state || return 1
  if [ "$force" != 1 ]; then
    [ -f "$MSM_DEST" ] && [ "$(sha "$MSM_DEST")" = "$staged_msm_sha" ] || {
      say 'FATAL: installed MSM differs from staged candidate; refusing to overwrite'; return 1;
    }
    if [ "$has_initrd" = 1 ] && [ "$(sha "$INITRD")" != "$staged_initrd_sha" ]; then
      say 'FATAL: initrd changed since MSM staging; refusing to overwrite'; return 1
    fi
  fi
  if [ "$had_override" = 1 ]; then
    install -D -m 0644 "$STATE/msm.before" "$MSM_DEST" || return 1
  else
    rm -f "$MSM_DEST" || return 1
  fi
  depmod -a "$KVER" || return 1
  if [ "$has_initrd" = 1 ]; then cp -a "$STATE/initrd.before" "$INITRD" || return 1; fi
  if [ "$had_override" = 1 ]; then
    [ "$(sha "$MSM_DEST")" = "$prior_msm_sha" ] || return 1
    [ "$(resolved msm)" = "$MSM_DEST" ] || return 1
  fi
  if [ "$has_initrd" = 1 ]; then [ "$(sha "$INITRD")" = "$prior_initrd_sha" ] || return 1; fi
  rm -rf "$STATE"
  say 'VERIFIED: previous MSM module and (if changed) original initrd restored.'
}

stage() {
  local entries had=0 has_initrd=0
  [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dpnext'; return 1; }
  [ ! -e "$STATE" ] && [ ! -e "$QMP_STATE" ] || {
    say 'FATAL: DP trial already staged or QMP has separate rollback state. Revert first.'; return 1;
  }
  preflight || return 1
  mkdir -m 0700 -p "$STATE" || return 1
  if [ -f "$MSM_DEST" ]; then had=1; cp -a "$MSM_DEST" "$STATE/msm.before" || { rm -rf "$STATE"; return 1; }; fi
  if [ -f "$INITRD" ]; then
    command -v lsinitramfs >/dev/null || { say 'FATAL: lsinitramfs unavailable'; rm -rf "$STATE"; return 1; }
    entries="$(lsinitramfs "$INITRD")" || { say 'FATAL: cannot inspect initrd'; rm -rf "$STATE"; return 1; }
    case "$entries" in *msm.ko*) has_initrd=1; cp -a "$INITRD" "$STATE/initrd.before" || { rm -rf "$STATE"; return 1; } ;; esac
  fi
  printf 'HAD_OVERRIDE=%s\nHAS_INITRD=%s\nPRIOR_MSM_SHA=%s\nSTAGED_MSM_SHA=%s\nPRIOR_INITRD_SHA=%s\nSTAGED_INITRD_SHA=%s\n' \
    "$had" "$has_initrd" "$(sha "$MSM_DEST")" "$(sha "$MSM_KO")" \
    "$([ "$has_initrd" = 1 ] && sha "$INITRD" || true)" \
    "$([ "$has_initrd" = 1 ] && sha "$INITRD" || true)" > "$STATE/state"
  chmod 0600 "$STATE/state"
  say "Staging MSM override: $MSM_DEST"
  install -D -m 0644 "$MSM_KO" "$MSM_DEST" || { say 'MSM install failed; restoring'; restore_msm 1; return 1; }
  depmod -a "$KVER" || { say 'depmod failed; restoring'; restore_msm 1; return 1; }
  if [ "$has_initrd" = 1 ]; then
    say "Updating initrd: $INITRD"
    update-initramfs -u -k "$KVER" || { say 'initrd update failed; restoring'; restore_msm 1; return 1; }
    entries="$(lsinitramfs "$INITRD")" || { say 'initrd unreadable after update; restoring'; restore_msm 1; return 1; }
    case "$entries" in *updates/a16/msm.ko*) ;; *) say 'FATAL: initrd lacks MSM override; restoring'; restore_msm 1; return 1 ;; esac
    printf 'STAGED_INITRD_SHA=%s\n' "$(sha "$INITRD")" >> "$STATE/state"
  fi
  if [ "$(resolved msm)" != "$MSM_DEST" ] || [ "$(sha "$MSM_DEST")" != "$(sha "$MSM_KO")" ]; then
    say 'FATAL: MSM resolver or installed bytes differ; restoring MSM'
    restore_msm 1 || say "ROLLBACK BLOCKED: inspect $STATE"
    return 1
  fi
  say 'MSM staged; now stage the previously built QMP PHY (no live reload).'
  if ! bash "$QMP_HELPER" stage; then
    say 'QMP stage failed; restoring MSM if QMP rollback is complete.'
    if [ -f "$QMP_STATE" ]; then say 'QMP rollback state remains: inspect/revert it before MSM'; return 1; fi
    restore_msm 1 || say "ROLLBACK BLOCKED: inspect $STATE"
    return 1
  fi
  [ -f "$QMP_STATE" ] || { say 'FATAL: QMP stage returned without rollback state'; return 1; }
  if [ "$(resolved msm)" != "$MSM_DEST" ] || [ "$(sha "$MSM_DEST")" != "$(sha "$MSM_KO")" ]; then
    say 'FATAL: MSM override changed during QMP staging; reverting both candidates.'
    revert || say 'ROLLBACK BLOCKED: inspect both staging records before reboot.'
    return 1
  fi
  if [ "$has_initrd" = 1 ]; then
    entries="$(lsinitramfs "$INITRD")" || { say 'FATAL: staged initrd unreadable'; revert; return 1; }
    case "$entries" in *updates/a16/msm.ko*) ;; *) say 'FATAL: final initrd lacks MSM override'; revert; return 1 ;; esac
  fi
  say 'VERIFIED: MSM resolver, installed bytes, and (if present) final initrd entry match the candidate.'
  say 'STAGED: both modules for NEXT boot only; live modules were not swapped.'
  say 'Reboot with monitor unplugged. Verify both loaded versions before one watched hotplug.'
  say 'Rollback: sudo bash ~/a16.sh dpnext revert ; then reboot.'
}

revert() {
  [ "$(id -u)" = 0 ] || { say 'Root required: sudo bash ~/a16.sh dpnext revert'; return 1; }
  [ -f "$STATE/state" ] || { say 'No DP-next state to revert; nothing changed.'; return 0; }
  read_state || return 1
  if [ -f "$QMP_STATE" ]; then
    say 'Reverting QMP first; its initrd backup is the MSM-staged state.'
    bash "$QMP_HELPER" revert || { say 'QMP revert failed; MSM untouched'; return 1; }
  elif [ "$(resolved phy-qcom-qmp-combo)" != "/lib/modules/$KVER/kernel/drivers/phy/qualcomm/phy-qcom-qmp-combo.ko" ]; then
    say 'FATAL: QMP override is still selected but rollback state is missing; MSM untouched.'
    return 1
  fi
  [ ! -f "$QMP_STATE" ] || { say 'FATAL: QMP rollback state remains; MSM untouched'; return 1; }
  restore_msm || { say "FATAL: MSM restore blocked; state retained at $STATE"; return 1; }
  say 'REVERTED: prior modules and initrd restored; reboot to change loaded code.'
}

case "$MODE" in
  status) show_status ;;
  dry-run) preflight; show_status; say 'DRY RUN: no module, initrd, or boot files changed.' ;;
  stage) stage ;;
  revert) revert ;;
  *) say 'usage: sudo bash ~/a16.sh dpnext [stage|revert|status|dry-run]'; exit 2 ;;
esac
say "log: $LOG"
