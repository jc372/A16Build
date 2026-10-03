#!/usr/bin/env bash
# a16-set-default-entry.sh -- which menu entry the A16 boots unattended.
#
#   type this:                 sudo bash ~/a16.sh default 3      # entry [3] = the display entry
#                              sudo bash ~/a16.sh default 2      # fall back to [2] if [3] stops working
#                              bash ~/a16.sh default status      # read-only: what is set now, per file
#
# Standing choice on this machine: entry **[3]** ("next 7.3 + glymur DTB, full display attempt"),
# timeout 30 s with the menu shown, so [2] is still reachable by hand when [3] fails.
#
# Two traps this script exists to close, both learned on this machine:
#   * the menu lives in FOUR byte-identical files on the ESP -- /a16boot/grub.cfg plus the copies
#     under /EFI/Boot, /EFI/ubuntu and /EFI/ubuntu_snapdragon.  The firmware does not necessarily
#     read the one you edited, so every copy has to change together.
#   * `set default=N` is a *position*, not the label: the titles say "[0]".."[8]" but the value is
#     the menuentry's index.  The script prints the title that index N actually selects.
#
# It only changes the `set default=` line: permissions, ownership and the rest of the file are kept.
# /etc/default/grub is reported but not changed -- that file only feeds the generated
# /boot/grub/grub.cfg, which is what entry [5] boots; the firmware path never reads it.
set -u

MODE="${1:-status}"
DEFAULT_CFGS="/boot/efi/a16boot/grub.cfg /boot/efi/EFI/Boot/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
CFGS="${A16_GRUB_CFG:-$DEFAULT_CFGS}"
say() { printf '%s\n' "$*"; }

case "$MODE" in
  status) ;;
  ''|*[!0-9]*) say "usage: bash $0 [status|N]   (N = menuentry index, e.g. 3)"; exit 2;;
esac

if [ "$(id -u)" != 0 ] && [ "${A16_SKIP_ROOT:-0}" != 1 ]; then
  say "This needs root. Type exactly this line:"
  say ""
  say "    sudo bash ~/a16.sh default $MODE"
  say ""
  exit 1
fi

python3 - "$MODE" $CFGS <<'PY'
import os, re, shutil, stat, sys

mode = sys.argv[1]
cfgs = [c for c in sys.argv[2:] if os.path.exists(c)]
if not cfgs:
    print("FATAL: none of the expected ESP configs exist"); sys.exit(1)

want = None if mode == "status" else int(mode)
changed, mismatch = [], []
for c in cfgs:
    src = open(c).read()
    m = re.search(r'^(\s*set default=)(\d+)(\s*)$', src, re.M)
    if not m:
        print("%-38s NO 'set default=' LINE -- left alone" % c); continue
    entries = re.findall(r'^\s*menuentry\s+"([^"]+)"', src, re.M)
    cur = int(m.group(2))
    cur_title = entries[cur] if cur < len(entries) else "<out of range>"
    if want is None:
        print("%-38s default=%-2d -> %s" % (c, cur, cur_title))
        continue
    if want >= len(entries):
        print("FATAL: index %d not in %s (%d entries)" % (want, c, len(entries))); sys.exit(1)
    if cur == want:
        print("%-38s already default=%d -> %s" % (c, want, entries[want]))
        continue
    st = os.stat(c)
    out = src[:m.start(2)] + str(want) + src[m.end(2):]
    tmp = c + ".a16new"
    with open(tmp, "w") as f:
        f.write(out)
    os.chmod(tmp, stat.S_IMODE(st.st_mode))
    shutil.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, c)
    after = re.search(r'^(\s*set default=)(\d+)(\s*)$', open(c).read(), re.M)
    changed.append(c)
    print("%-38s default %d -> %d  -> %s" % (c, cur, int(after.group(2)), entries[want]))
    if int(after.group(2)) != want:
        mismatch.append(c)

if want is None:
    print("\n(/etc/default/grub: GRUB_DEFAULT=%s -- only the generated config's entry [5] path uses it)"
          % (re.search(r'^GRUB_DEFAULT=(.*)$', open('/etc/default/grub').read(), re.M).group(1).strip()
             if os.path.exists('/etc/default/grub') else '?'))
    sys.exit(0)

if mismatch:
    print("\nFAILED on: %s" % " ".join(mismatch)); sys.exit(1)

# The four copies must stay byte-identical: the firmware may read any of them.
digests = {c: __import__('hashlib').sha256(open(c, 'rb').read()).hexdigest() for c in cfgs}
if len(set(digests.values())) != 1:
    print("\nWARNING: the ESP copies are no longer identical -- the firmware may read the stale one:")
    for c, d in digests.items():
        print("   %s  %s" % (d[:16], c))
else:
    print("\nAll %d ESP copies are byte-identical." % len(cfgs))

print("""
What this means: the menu still shows for 30 s, so entry [2] ("panel left to firmware") stays
reachable by hand if [3] ever fails to reach a desktop.  Nothing else about the entries changed.""")
PY
