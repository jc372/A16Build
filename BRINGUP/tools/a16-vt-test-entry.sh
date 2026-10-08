#!/usr/bin/env bash
# a16-vt-test-entry.sh -- test whether `keep_bootcon` is what stops the console handing the display
# over to the compositor when the monitor is attached at boot, and capture why msm rejects the first
# atomic commit if it still does.
#
#   report   bash ~/A16Build/BRINGUP/tools/a16-vt-test-entry.sh              # read-only
#   apply    sudo bash ~/A16Build/BRINGUP/tools/a16-vt-test-entry.sh apply   # add the test entry
#   read     sudo bash ~/A16Build/BRINGUP/tools/a16-vt-test-entry.sh read    # after the test boot
#   remove   sudo bash ~/A16Build/BRINGUP/tools/a16-vt-test-entry.sh remove  # take it back out
#
# Design rule, same as a16-recovery-entry.sh: do NOT author boot entries.  The known-good entry
# 'A16: linux-next 7.3.0-rc5-next-20261002-t2' is read out of the menu and cloned VERBATIM; only the
# cmdline suffix and the title change.  search/insmod/fdt/devicetree/initrd/guards all come from the
# entry that boots, so this cannot have the unset-variable class of bug.
#
# What the clone changes (two variables, so a failure is interpretable):
#   - drops  keep_bootcon     -> keeps a boot console alive beside the real one; the suspect, because
#                               at boot fbcon stays bound (vtcon1 bind=1) and the compositor's commits
#                               are refused, while a manual VT round trip makes the display hand over
#   - adds   drm.debug=0x1ff  -> if it still refuses, the kernel says which part of the atomic state
#                               it rejects (DRM_UT_*), instead of the silent EINVAL we have now
#
# The entry is APPENDED (last row of the menu) and titled, so nothing above it shifts.
set -u

MODE="${1:-report}"
BASE_TITLE='A16: linux-next 7.3.0-rc5-next-20261002-t2'
TEST_TITLE='A16: TEST - t2 no keep_bootcon + drm.debug (HDMI boot freeze)'
MARKER='# added by a16-vt-test-entry.sh'
DEFAULT_CFGS="/boot/efi/a16boot/grub.cfg /boot/efi/EFI/Boot/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/ubuntu_snapdragon/grub.cfg"
CFGS="${A16_GRUB_CFG:-$DEFAULT_CFGS}"

# Non-root is allowed only when A16_GRUB_CFG points somewhere else (i.e. a test copy of the menu).
if [ "$MODE" != report ] && [ "$MODE" != read ] && [ "$(id -u)" != 0 ] && [ -z "${A16_GRUB_CFG:-}" ]; then
	printf 'This mode edits the ESP.  Type exactly:\n\n    sudo bash ~/A16Build/BRINGUP/tools/a16-vt-test-entry.sh %s\n\n' "$MODE"
	exit 1
fi

case "$MODE" in
report)
	echo "=== a16-vt-test-entry report (read-only) ==="
	python3 - "$MODE" "$BASE_TITLE" "$TEST_TITLE" "$MARKER" $CFGS <<'PY'
import os, re, sys
mode, base_title, test_title, marker = sys.argv[1:5]
cfgs = [c for c in sys.argv[5:] if os.path.exists(c)]
if not cfgs:
    print("  no ESP config files found at the expected paths")
for c in cfgs:
    txt = open(c, encoding="utf-8", errors="replace").read()
    titles = re.findall(r'menuentry "([^"]*)"', txt)
    has_base = base_title in txt
    has_test = marker in txt
    kb = 'keep_bootcon' in txt
    print("\n-- %s" % c)
    print("   entries: %d" % len(titles))
    for i, t in enumerate(titles, 1):
        print("     %2d. %s" % (i, t))
    print("   known-good entry present: %s   keep_bootcon present: %s   test entry present: %s"
          % (has_base, kb, has_test))
PY
	;;
apply)
	echo "=== a16-vt-test-entry: adding the test entry to every ESP config ==="
	python3 - "$MODE" "$BASE_TITLE" "$TEST_TITLE" "$MARKER" $CFGS <<'PY'
import os, re, shutil, sys
mode, base_title, test_title, marker = sys.argv[1:5]
cfgs = [c for c in sys.argv[5:] if os.path.exists(c)]
rc = 0
def block(txt, title):
    """return (start, end, text) of the menuentry block with this title, or None"""
    m = re.search(r'^[ \t]*menuentry "%s" \{' % re.escape(title), txt, re.M)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(txt) and depth:
        if txt[i] == '{':
            depth += 1
        elif txt[i] == '}':
            depth -= 1
        i += 1
    return (m.start(), i, txt[m.start():i])
for c in cfgs:
    txt = open(c, encoding="utf-8", errors="replace").read()
    if marker in txt:
        print("  %s: already has the test entry -- skipped (idempotent)" % c)
        continue
    b = block(txt, base_title)
    if not b:
        print("  %s: known-good entry NOT found -- skipped (refusing to author one)" % c)
        rc = 1
        continue
    src = b[2]
    clone = src.replace('menuentry "%s"' % base_title, 'menuentry "%s"' % test_title, 1)
    # cmdline only -- never the title: drop keep_bootcon, append drm.debug
    def fix_cmdline(m):
        line = re.sub(r'[ \t]+keep_bootcon\b', '', m.group(1))
        return line.rstrip() + ' drm.debug=0x1ff'
    clone = re.sub(r'^([ \t]*linux [^\n]*)$', fix_cmdline, clone, flags=re.M)
    linux_lines = [l for l in clone.splitlines() if l.lstrip().startswith('linux ')]
    ok = bool(linux_lines) and all('keep_bootcon' not in l for l in linux_lines) \
         and any('drm.debug=0x1ff' in l for l in linux_lines)
    if not ok:
        print("  %s: clone cmdline did not come out as expected -- NOT written" % c)
        rc = 1
        continue
    bak = c + '.a16-vt-test.bak'
    if not os.path.exists(bak):
        shutil.copy2(c, bak)
    out = txt.rstrip('\n') + '\n\n' + marker + ' (clone of "' + base_title + '")\n' + clone + '\n'
    open(c, 'w', encoding="utf-8").write(out)
    print("  %s: test entry added (backup: %s)" % (c, bak))
print("\n  Pick it by NAME in the GRUB menu (last row):\n    %s" % test_title)
print("  If it does not reach a desktop, the failsafe entry (msm blacklisted) and the recovery entry")
print("  (multi-user) are unchanged, and 'remove' puts everything back.")
sys.exit(rc)
PY
	;;
remove)
	echo "=== a16-vt-test-entry: removing the test entry ==="
	python3 - "$MODE" "$BASE_TITLE" "$TEST_TITLE" "$MARKER" $CFGS <<'PY'
import os, sys
mode, base_title, test_title, marker = sys.argv[1:5]
cfgs = [c for c in sys.argv[5:] if os.path.exists(c)]
for c in cfgs:
    bak = c + '.a16-vt-test.bak'
    if os.path.exists(bak):
        open(c, 'w', encoding="utf-8").write(open(bak, encoding="utf-8").read())
        os.remove(bak)
        print("  %s: restored from backup" % c)
    else:
        print("  %s: no backup -> nothing to restore" % c)
PY
	;;
read)
	echo "=== a16-vt-test-entry: what the test boot said (previous boot) ==="
	if ! journalctl -b -1 -k --no-pager >/dev/null 2>&1; then
		echo "  no previous boot in the journal"
		exit 1
	fi
	echo "-- page-flip failures in that boot:"
	journalctl -b -1 --no-pager 2>/dev/null | grep -c 'Page flip failed' | sed 's/^/     /'
	echo "-- first failure, with the kernel log just before it:"
	first=$(journalctl -b -1 --no-pager -o short-iso 2>/dev/null | grep -n -m1 'Page flip failed' | cut -d: -f1)
	if [ -n "${first:-}" ]; then
		journalctl -b -1 --no-pager -o short-iso 2>/dev/null | sed -n "$((first-25)),$((first+2))p" | cut -c1-165
	else
		echo "     none -- the display came up in that boot"
	fi
	echo
	echo "-- what the kernel said about atomic/commit failures (drm.debug=0x1ff would be in here):"
	journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'atomic|EINVAL|invalid|reject|fail|bw|bandwidth|mixer|plane|modifier|unsupported' | tail -25 | cut -c1-165
	echo
	echo "-- did keep_bootcon take effect / was it dropped? cmdline of that boot:"
	journalctl -b -1 -k --no-pager 2>/dev/null | grep -m1 -oE 'Kernel command line:.*' | cut -c1-200
	;;
*)
	echo "unknown mode '$MODE' -- use report | apply | read | remove"
	exit 2
	;;
esac
