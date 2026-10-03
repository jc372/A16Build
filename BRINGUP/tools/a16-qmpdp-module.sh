#!/usr/bin/env bash
# Stage the locally built Glymur/QMP combo-PHY module for one controlled DP test.
#
#   sudo bash ~/a16.sh qmpdp          stage for next boot; does not reboot or hotplug
#   bash ~/a16.sh qmpdp status        inspect the candidate/installed/loaded module
#   sudo bash ~/a16.sh qmpdp revert   remove override and restore the prior initrd
#
# The stock module is never overwritten. Rollback files are under
# /var/lib/a16-qmpdp/<kernel-release>/; logs are under ~/a16-payload/.
set -u

MODE="${1:-stage}"
RUNNING_KVER="$(uname -r)"
KVER="$RUNNING_KVER"
KO="${A16_QMP_KO:-/home/jc/build/linux-next-1a1de54f7369-qmp-v5/drivers/phy/qualcomm/phy-qcom-qmp-combo.ko}"
TEST_MODE="${A16_QMP_TEST_MODE:-0}"
TEST_ROOT="${A16_QMP_TEST_ROOT:-}"

if [ -n "$TEST_ROOT" ]; then
  [ "$TEST_MODE" = 1 ] || { printf 'A16_QMP_TEST_ROOT requires A16_QMP_TEST_MODE=1\n' >&2; exit 2; }
  TEST_ROOT="${TEST_ROOT%/}"
  rooted() { printf '%s%s' "$TEST_ROOT" "$1"; }
else
  rooted() { printf '%s' "$1"; }
fi

REVERT_AMBIGUOUS=0
STATE_BASE="$(rooted "/var/lib/a16-qmpdp")"
if [ "$MODE" = revert ] && [ ! -f "$STATE_BASE/$KVER/state" ]; then
  states=()
  for state in "$STATE_BASE"/*/state; do
    [ -f "$state" ] && states+=("$state")
  done
  if [ "${#states[@]}" = 1 ]; then
    saved_dir="${states[0]%/state}"
    KVER="${saved_dir##*/}"
  elif [ "${#states[@]}" -gt 1 ]; then
    REVERT_AMBIGUOUS=1
  fi
fi

STOCK="$(rooted "/lib/modules/$KVER/kernel/drivers/phy/qualcomm/phy-qcom-qmp-combo.ko")"
DEST_DIR="$(rooted "/lib/modules/$KVER/updates/a16")"
DEST="$DEST_DIR/phy-qcom-qmp-combo.ko"
INITRD="$(rooted "/boot/initrd.img-$KVER")"
STATE_DIR="$(rooted "/var/lib/a16-qmpdp/$KVER")"
PAYLOAD="$(rooted "/home/jc/a16-payload")"
LOG="${A16_LOG:-$PAYLOAD/qmpdp-$(date +%Y%m%d-%H%M%S).log}"

say() { printf '%s\n' "$*"; }
rule() { say '----------------------------------------------------------------'; }
file_srcversion() { modinfo -F srcversion "$1" 2>/dev/null || true; }
file_vermagic() { modinfo -F vermagic "$1" 2>/dev/null || true; }
crcs() { modprobe --dump-modversions "$1" 2>/dev/null | sort; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 1
exec > >(tee -a "$LOG") 2>&1
say "=== a16-qmpdp-module $(date '+%Y-%m-%d %H:%M:%S') mode=$MODE kernel=$KVER ==="
say "log: $LOG"
if [ "$REVERT_AMBIGUOUS" = 1 ]; then
  say 'FATAL: multiple saved QMP rollback states exist; refusing to guess which kernel to revert.'
  say "Inspect: $STATE_BASE/*/state"
  exit 1
fi
if [ "$MODE" = revert ] && [ "$KVER" != "$RUNNING_KVER" ]; then
  say "Reverting saved kernel $KVER while currently running $RUNNING_KVER."
fi

case "$MODE" in
  status)
    say "candidate: $KO"
    if [ -f "$KO" ]; then
      say "candidate vermagic: $(file_vermagic "$KO")"
      say "candidate srcversion: $(file_srcversion "$KO")"
      say "candidate sha256: $(sha256sum "$KO" | cut -d' ' -f1)"
    else say 'candidate: MISSING'; fi
    say "stock: $STOCK"
    say "override: $DEST"
    if [ -f "$DEST" ]; then
      say "override srcversion: $(file_srcversion "$DEST")"
      say "override sha256: $(sha256sum "$DEST" | cut -d' ' -f1)"
    else say 'override: not installed'; fi
    if [ -f /sys/module/phy_qcom_qmp_combo/srcversion ]; then
      say "loaded srcversion: $(< /sys/module/phy_qcom_qmp_combo/srcversion)"
    else say 'loaded srcversion: module not loaded'; fi
    if [ -n "$TEST_ROOT" ]; then
      if [ -f "$DEST" ]; then say "test-root resolver: $DEST"; else say "test-root resolver: $STOCK"; fi
    else
      say "resolver: $(modinfo -k "$KVER" -F filename phy-qcom-qmp-combo 2>/dev/null || printf 'unresolved')"
    fi
    if [ -d "$STATE_DIR" ]; then say "rollback state: present at $STATE_DIR"; else say 'rollback state: none'; fi
    say "log: $LOG"
    exit 0 ;;
  stage|revert) ;;
  *) say "usage: bash $0 [stage|status|revert]"; exit 2 ;;
esac

if [ "$TEST_MODE" != 1 ] && [ "$(id -u)" != 0 ]; then
  say 'This needs root. Type exactly:'
  say '    sudo bash ~/a16.sh qmpdp'
  exit 1
fi

restore_stage_state() {
  local had_override="$1" has_initrd="$2"
  if [ "$had_override" = 1 ] && [ -f "$STATE_DIR/previous-override.ko" ]; then
    install -D -m 0644 "$STATE_DIR/previous-override.ko" "$DEST" || return 1
  else
    rm -f "$DEST" || return 1
  fi
  depmod -a "$KVER" || return 1
  if [ "$has_initrd" = 1 ] && [ -f "$STATE_DIR/initrd.before" ]; then
    cp -a "$STATE_DIR/initrd.before" "$INITRD" || return 1
  fi
  return 0
}

validate_candidate() {
  [ -f "$KO" ] || { say "FATAL: candidate module missing: $KO"; return 1; }
  [ -f "$STOCK" ] || { say "FATAL: stock module missing: $STOCK"; return 1; }
  local vm stock_vm mismatch
  vm="$(file_vermagic "$KO")"
  stock_vm="$(file_vermagic "$STOCK")"
  if [ -z "$vm" ] || [ "$vm" != "$stock_vm" ] || [[ "$vm" != "$KVER "* ]]; then
    say "FATAL: vermagic mismatch; candidate='$vm' stock='$stock_vm' running='$KVER'"
    return 1
  fi
  mismatch="$(comm -3 <(crcs "$STOCK") <(crcs "$KO"))"
  if [ -n "$mismatch" ]; then
    say 'FATAL: candidate imports/CRCs differ from stock; refusing to stage:'
    printf '%s\n' "$mismatch"
    return 1
  fi
  say "candidate ABI: vermagic and all $(crcs "$KO" | wc -l | tr -d ' ') imported symbol CRCs match stock"
  say "candidate srcversion: $(file_srcversion "$KO")"
  say "candidate sha256: $(sha256sum "$KO" | cut -d' ' -f1)"
}

stage() {
  local had_override=0 has_initrd=0 entries installed_sha resolved staged_initrd_sha
  if [ -d "$STATE_DIR" ]; then
    if [ -f "$STATE_DIR/state" ] && [ -f "$DEST" ] && \
       [ "$(sha256sum "$DEST" | cut -d' ' -f1)" = "$(sha256sum "$KO" | cut -d' ' -f1)" ]; then
      say 'This exact candidate is already staged; no changes made.'
      say 'Revert with: sudo bash ~/a16.sh qmpdp revert'
      return 0
    fi
    say "FATAL: rollback state already exists at $STATE_DIR; inspect or revert before staging again."
    return 1
  fi

  validate_candidate || return 1
  mkdir -p "$STATE_DIR" || { say "FATAL: cannot create $STATE_DIR"; return 1; }
  chmod 0700 "$STATE_DIR" || return 1
  if [ -f "$DEST" ]; then
    had_override=1
    cp -a "$DEST" "$STATE_DIR/previous-override.ko" || { rm -rf "$STATE_DIR"; return 1; }
  fi
  if [ -f "$INITRD" ] && command -v lsinitramfs >/dev/null 2>&1; then
    entries="$(lsinitramfs "$INITRD" 2>/dev/null)" || entries=''
    case "$entries" in
      *phy-qcom-qmp-combo.ko*)
        has_initrd=1
        cp -a "$INITRD" "$STATE_DIR/initrd.before" || { rm -rf "$STATE_DIR"; return 1; }
        ;;
    esac
  fi
  cp -f "$KO" "$STATE_DIR/candidate.ko" || { rm -rf "$STATE_DIR"; return 1; }
  printf 'HAD_OVERRIDE=%s\nHAS_INITRD=%s\n' "$had_override" "$has_initrd" > "$STATE_DIR/state"
  chmod 0600 "$STATE_DIR/state" || { rm -rf "$STATE_DIR"; return 1; }

  say "staging override at $DEST"
  if ! install -D -m 0644 "$KO" "$DEST"; then
    say 'FATAL: module copy failed; rolling back.'
    restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
    rm -rf "$STATE_DIR"
    return 1
  fi
  if ! depmod -a "$KVER"; then
    say 'FATAL: depmod failed; rolling back.'
    restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
    rm -rf "$STATE_DIR"
    return 1
  fi

  if [ "$has_initrd" = 1 ]; then
    say "initrd contains combo-PHY; updating $INITRD"
    if ! update-initramfs -u -k "$KVER"; then
      say 'FATAL: update-initramfs failed; rolling back.'
      restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
      rm -rf "$STATE_DIR"
      return 1
    fi
    entries="$(lsinitramfs "$INITRD" 2>/dev/null)" || entries=''
    case "$entries" in
      *updates/a16/phy-qcom-qmp-combo.ko*) say 'initrd verified: updates/a16 combo-PHY module is present' ;;
      *)
        say 'FATAL: updated initrd lacks the updates/a16 combo-PHY module; rolling back.'
        restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
        rm -rf "$STATE_DIR"
        return 1
        ;;
    esac
    staged_initrd_sha="$(sha256sum "$INITRD" | cut -d' ' -f1)"
    printf 'STAGED_INITRD_SHA=%s\n' "$staged_initrd_sha" >> "$STATE_DIR/state"
  else
    say 'initrd does not contain this module; no initrd changes needed'
  fi

  if [ "$TEST_MODE" != 1 ]; then
    resolved="$(modinfo -k "$KVER" -F filename phy-qcom-qmp-combo 2>/dev/null || true)"
    if [ "$resolved" != "$DEST" ]; then
      say "FATAL: resolver selected '$resolved', expected '$DEST'; rolling back."
      restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
      rm -rf "$STATE_DIR"
      return 1
    fi
  fi
  installed_sha="$(sha256sum "$DEST" | cut -d' ' -f1)"
  if [ "$installed_sha" != "$(sha256sum "$KO" | cut -d' ' -f1)" ]; then
    say 'FATAL: installed module differs from candidate; rolling back.'
    restore_stage_state "$had_override" "$has_initrd" || say 'ROLLBACK ERROR: inspect module/initrd manually.'
    rm -rf "$STATE_DIR"
    return 1
  fi

  say "VERIFIED: $DEST is byte-identical to $KO"
  say "rollback data: $STATE_DIR"
  rule
  say 'STAGED FOR NEXT BOOT ONLY. No live module unload/load was attempted.'
  say 'Do not connect USB-C until after reboot and the capture watcher is running.'
  say 'Next: sudo reboot; after login run: sudo bash ~/a16.sh display watch; then connect once.'
  say 'If boot/display fails, use fallback GRUB entry [2], then: sudo bash ~/a16.sh qmpdp revert'
  return 0
}

revert() {
  local had_override='' has_initrd='' staged_initrd_sha=''
  [ -f "$STATE_DIR/state" ] || { say "No staged state at $STATE_DIR; nothing changed."; return 0; }
  while IFS='=' read -r key value; do
    case "$key" in
      HAD_OVERRIDE) had_override="$value" ;;
      HAS_INITRD) has_initrd="$value" ;;
      STAGED_INITRD_SHA) staged_initrd_sha="$value" ;;
    esac
  done < "$STATE_DIR/state"
  case "$had_override:$has_initrd" in 0:0|0:1|1:0|1:1) ;; *) say 'FATAL: invalid rollback state; refusing.'; return 1 ;; esac
  if [ "$had_override" = 1 ] && [ ! -f "$STATE_DIR/previous-override.ko" ]; then
    say 'FATAL: previous module backup is missing; refusing to remove the staged override.'
    return 1
  fi
  if [ "$has_initrd" = 1 ]; then
    if [ ! -f "$STATE_DIR/initrd.before" ] || [ -z "$staged_initrd_sha" ]; then
      say 'FATAL: initrd rollback data is incomplete; refusing to change module/initrd.'
      return 1
    fi
    current_initrd_sha="$(sha256sum "$INITRD" | cut -d' ' -f1)"
    if [ "$current_initrd_sha" != "$staged_initrd_sha" ]; then
      say 'FATAL: initrd changed since staging; refusing to overwrite a newer initrd backup.'
      return 1
    fi
  fi

  if [ "$had_override" = 1 ] && [ -f "$STATE_DIR/previous-override.ko" ]; then
    install -D -m 0644 "$STATE_DIR/previous-override.ko" "$DEST" || return 1
  else
    rm -f "$DEST" || return 1
  fi
  depmod -a "$KVER" || { say 'FATAL: depmod failed during revert; staged state retained.'; return 1; }
  if [ "$has_initrd" = 1 ] && [ -f "$STATE_DIR/initrd.before" ]; then
    cp -a "$STATE_DIR/initrd.before" "$INITRD" || { say 'FATAL: initrd restore failed; staged state retained.'; return 1; }
  fi
  rm -rf "$STATE_DIR"
  say 'REVERTED: module override removed/restored and original initrd restored.'
  say 'Reboot before retesting; the currently loaded module remains in memory until reboot.'
  say "log: $LOG"
  return 0
}

if [ "$MODE" = stage ]; then stage; else revert; fi
