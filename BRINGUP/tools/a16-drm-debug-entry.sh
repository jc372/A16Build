#!/usr/bin/env bash
# a16-drm-debug-entry.sh -- put `drm.debug=0x1ff` into the A16 display entry so one boot records
#                           what msm/DP actually does.  EVERY ESP config that carries the menu is
#                           changed, because the firmware may read any of them.
#
#   sudo bash a16-drm-debug-entry.sh arm          # == what you want: entry [3] carries the parameter
#   sudo bash a16-drm-debug-entry.sh add inline   # (same thing, keeps any separate row as well)
#   sudo bash a16-drm-debug-entry.sh add          # a separate row (entry [9]) instead
#   sudo bash a16-drm-debug-entry.sh remove inline | remove     # undo either form
#   bash a16-drm-debug-entry.sh status            # read-only: per config, what is there?
#
# Use `arm`: one command, then reboot and pick [3] -- the row you already use.  It also deletes any
# separate debug row, so the menu does not accumulate.
#
# Two traps this script exists to close, both learned the hard way on this machine:
#   * the menu lives in FOUR files on the ESP -- our staged /a16boot/grub.cfg plus three
#     byte-identical copies under /EFI/Boot, /EFI/ubuntu and /EFI/ubuntu_snapdragon.  Editing only
#     /a16boot/grub.cfg did nothing: the firmware does not boot that copy, so the "debug" boot came
#     up without drm.debug and looked exactly like the boot before it.
#   * a separate row is inserted after entry [3] in file order, i.e. it shows as row 5, not at the
#     bottom -- easy to miss.  `inline` removes the row question: pick [3], the row you know.
#
# Why drm.debug=0x1ff: the panel fails with
#     msm_dp_ctrl_link_train_1_2: *ERROR* link training #2 on phy 0 failed. ret=-110
#     msm_dp_aux_isr: *ERROR* Unexpected DP AUX IRQ 0x01000000 when not busy
# and 0x01000000 is DP_INTR_PLL_UNLOCKED (BIT(24), drivers/gpu/drm/msm/dp/dp_reg.h) -- the eDP PHY's
# PLL unlocking, delivered to the AUX handler while it is idle.  -110 is an AUX *timeout* inside link
# training, which sits oddly beside plain AUX reads working (the probe read the panel's EDID:
# "ELD monitor ATNA60HR07-0", 30-120 Hz, 10 bpc).  Only DRM's own debug output says which AUX
# transaction times out and what the sink answered; that logging is drm_dbg_dp (DRM_UT_DP) and 0x1ff
# turns on every DRM category.
set -u

MODE="${1:-status}"
TARGET="${2:-auto}"
DEFAULT_CFGS="/boot/efi/a16boot/grub.cfg /boot/efi/EFI/Boot/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
CFGS="${A16_GRUB_CFG:-$DEFAULT_CFGS}"
PARAM='drm.debug=0x1ff'                  # the single-param form (separate row)
PARAMS="${A16_PARAMS:-drm.debug=0x1ff}"   # inline form: any set of cmdline params, space separated
TITLE='[9] A16: entry [3] + drm.debug=0x1ff (records what msm/DP does)'
say() { printf '%s\n' "$*"; }

case "$MODE" in
  add|remove|arm)
    blocked=""
    for f in $CFGS; do [ -f "$f" ] && [ ! -w "$f" ] && blocked="$blocked $f"; done
    [ -z "$blocked" ] || { say "not writable (needs root):$blocked"; exit 1; }
    ;;
esac

python3 - "$MODE" "$TARGET" "$PARAM" "$TITLE" "$PARAMS" $CFGS <<'PY'
import sys, re, os, shutil, datetime
mode, target, param, title, params = sys.argv[1:6]
params = params.split()
cfgs = [c for c in sys.argv[6:] if os.path.exists(c)]
if not cfgs:
    print("FATAL: none of the expected GRUB configs exist"); sys.exit(1)

def blocks(lines):
    out, start = [], None
    for i, l in enumerate(lines, 1):
        if l.startswith('menuentry '):
            if start is not None:
                out.append((start, i - 1))
            start = i
    if start is not None:
        out.append((start, len(lines)))
    return out

def block_of(lines, sub):
    for s, e in blocks(lines):
        if sub in lines[s-1]:
            return s, e
    return None, None

def first_linux(s, e, lines):
    for i in range(s-1, e):
        if re.match(r'\s*linux /boot/vmlinuz', lines[i]):
            return i
    return None

rep = []
for cfg in cfgs:
    lines = open(cfg).read().splitlines(keepends=True)
    s3, e3 = block_of(lines, '[3] ')
    inl = [i for i in range(s3-1, e3) if param in lines[i]] if s3 else []
    row = block_of(lines, title)[0] is not None
    n_menu = sum(1 for l in lines if l.startswith('menuentry '))
    bak = cfg + '.a16-drmdebug-bak'

    if mode == 'status':
        rep.append(f"{cfg}\n     entries={n_menu}  inline-in-[3]={'yes' if inl else 'no'}"
                   f"  separate-row={'yes' if row else 'no'}"
                   f"  backup={'yes' if os.path.exists(bak) else 'no'}")
        continue

    if mode == 'arm':
        # One command that makes entry [3] carry the parameter in every config, and clears any
        # separate debug row so the menu goes back to what it was.  This exists because "add inline"
        # followed by "pick [3]" only works if the *inline* form was actually used; with the plain
        # `add` the parameter lives in a new row, picking [3] boots without it, and the screen looks
        # exactly the same as before.
        did = []
        if row:
            s, e = block_of(lines, title)
            if not os.path.exists(bak): shutil.copy2(cfg, bak)
            start = s - 1
            if start > 0 and lines[start-1].strip() == '':
                start -= 1
            lines = lines[:start] + lines[e:]
            did.append('separate row removed')
        s3, e3 = block_of(lines, '[3] ')
        i = first_linux(s3, e3, lines) if s3 else None
        if i is None:
            rep.append(f"{cfg}: no entry [3] linux line -- unchanged ({', '.join(did) or 'nothing'})")
            continue
        want = [p for p in params if p not in lines[i]]
        if want:
            if not os.path.exists(bak): shutil.copy2(cfg, bak)
            lines[i] = lines[i].rstrip('\n') + ''.join(f' {p}' for p in want) + '\n'
            with open(cfg + '.a16-added-params', 'a') as fh:
                for p in want:
                    fh.write(p + '\n')
            did.append(f"{' '.join(want)} -> entry [3] line {i+1}")
        open(cfg, 'w').writelines(lines)
        rep.append(f"{cfg}: {'; '.join(did) if did else 'already armed -- unchanged'}")

    elif mode == 'add' and target == 'inline':
        if s3 is None:
            rep.append(f"{cfg}: no entry [3] -- unchanged"); continue
        i = first_linux(s3, e3, lines)
        if i is None:
            rep.append(f"{cfg}: entry [3] has no linux line -- unchanged"); continue
        if not os.path.exists(bak): shutil.copy2(cfg, bak)
        want = [p for p in params if p not in lines[i]]
        if not want:
            rep.append(f"{cfg}: all params already there -- unchanged"); continue
        lines[i] = lines[i].rstrip('\n') + ''.join(f' {p}' for p in want) + '\n'
        open(cfg, 'w').writelines(lines)
        with open(cfg + '.a16-added-params', 'a') as fh:
            for p in want:
                fh.write(p + '\n')
        rep.append(f"{cfg}: {' '.join(want)} -> entry [3], line {i+1}")

    elif mode == 'add':
        if row:
            rep.append(f"{cfg}: separate row already present -- unchanged"); continue
        if s3 is None:
            rep.append(f"{cfg}: no entry [3] -- unchanged"); continue
        out = []
        for l in lines[s3-1:e3]:
            if l.startswith('menuentry '):
                out.append(f'menuentry "{title}" {{\n')
            elif re.match(r'\s*linux /boot/vmlinuz', l):
                l = l.rstrip('\n')
                out.append(l + (f' {param}\n' if param not in l else '\n'))
            elif re.match(r'\s*echo ', l) and 'REAL display path' in l:
                out.append('    echo "  a copy of entry [3] with drm.debug=0x1ff: every DRM category logs"\n')
            else:
                out.append(l)
        if not any(param in l for l in out):
            rep.append(f"{cfg}: no linux line to carry it -- unchanged"); continue
        if not os.path.exists(bak): shutil.copy2(cfg, bak)
        open(cfg, 'w').writelines(lines[:e3] + ['\n'] + out + lines[e3:])
        rep.append(f"{cfg}: separate row added after entry [3] (shows as row 5)")

    elif mode == 'remove' and target == 'inline':
        side = cfg + '.a16-added-params'
        known = []
        if os.path.exists(side):
            known = [l.strip() for l in open(side) if l.strip()]
        known = known or params
        hits = []
        for i in range(s3-1, e3) if s3 else []:
            for p in known:
                if ' ' + p in lines[i]:
                    lines[i] = lines[i].replace(' ' + p, ''); hits.append(p)
        if not hits:
            rep.append(f"{cfg}: nothing of {known} in entry [3] -- unchanged"); continue
        shutil.copy2(cfg, cfg + '.a16-removed-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
        open(cfg, 'w').writelines(lines)
        if os.path.exists(side): os.unlink(side)
        rep.append(f"{cfg}: removed {' '.join(sorted(set(hits)))}")

    elif mode == 'remove':
        if not row:
            rep.append(f"{cfg}: no separate row -- unchanged"); continue
        s, e = block_of(lines, title)
        shutil.copy2(cfg, cfg + '.a16-removed-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
        start = s - 1
        if start > 0 and lines[start-1].strip() == '':
            start -= 1
        open(cfg, 'w').writelines(lines[:start] + lines[e:])
        rep.append(f"{cfg}: separate row removed (was lines {s}-{e})")

    else:
        rep.append(f"{cfg}: nothing to do for '{mode} {target}'")

print("\n".join(rep))
PY
rc=$?

if { [ "$MODE" = add ] || [ "$MODE" = arm ]; } && [ $rc -eq 0 ] && command -v grub-script-check >/dev/null 2>&1; then
  for f in $CFGS; do
    [ -f "$f" ] || continue
    if grub-script-check "$f" >/dev/null 2>&1; then say "grub-script-check clean: $f"
    else say "grub-script-check PROBLEM: $f  (undo: sudo bash $0 remove $TARGET)"; rc=1; fi
  done
fi
if { [ "$MODE" = add ] || [ "$MODE" = arm ]; } && [ $rc -eq 0 ]; then
  say ""
  say "Next: reboot and pick [3].  Undo later with: sudo bash $0 remove $TARGET"
fi
exit $rc
