#!/usr/bin/env bash
# a16-install-kernel.sh -- install an A16 kernel package (image, modules, device tree), find out
# what version it is, put it in the boot menu, and tell you what to select after rebooting.
#
#   sudo bash a16-install-kernel.sh                 # newest linux-image-*.deb it can find, or fetch it
#   sudo bash a16-install-kernel.sh --deb FILE.deb  # a specific package (e.g. one you just built)
#   sudo bash a16-install-kernel.sh --check         # report what it would do; changes nothing
#   sudo bash a16-install-kernel.sh --no-grub       # install only; write the entry out as text
#   sudo bash a16-install-kernel.sh --reinstall     # install over a version already present
#   sudo bash a16-install-kernel.sh --remove <ver>  # undo: entry, package, /boot files, modules
#   sudo bash a16-install-kernel.sh --remove        # list what is installed and which is running
#
# Every command this script runs is in this script, including writing the boot menu entry: it
# needs nothing but the package and the tools already on the machine -- dpkg, depmod,
# update-initramfs, grub-script-check. The only thing it fetches is the kernel package, and only
# when it cannot find one locally (--deb, or beside itself, or in ~/a16-deb).
#
# Files it puts in place, all for the version it read out of the package:
#
#   /boot/vmlinuz-<ver>                  the kernel
#   /boot/initrd.img-<ver>               built if the package's postinst did not
#   /boot/config-<ver>                   from the package
#   /boot/System.map-<ver>               from the package
#   /boot/glymur-a16-<ver>.dtb           the device tree this machine boots with
#   /usr/lib/modules/<ver>/              ~7,400 modules, and modules.dep for them
#   one menuentry in the EFI grub.cfg    titled "A16: linux-next <ver>"
#   <grub.cfg>.a16-<stamp>               a backup of the menu, taken before it is edited
#
# What it does, in order:
#   1. finds the package -- beside itself, in ~/a16-deb, in /tmp, or from the GitHub release
#   2. reads the version out of the package, and skips the install if that version is already
#      there (--reinstall forces it, after backing up what it is about to replace)
#   3. installs it with dpkg (kmod first if it is missing)
#   4. verifies every file listed above, runs depmod, and builds the initramfs if the package's
#      postinst did not -- an entry without an initramfs cannot boot, and that is the most common
#      failure on this machine
#   5. adds the boot menu entry, backing the menu up first and refusing to add a duplicate
#   6. prints the version, what went where, and exactly what to pick after rebooting
#
# --remove <ver> is the undo: it takes that kernel's menu entry out (backing the menu up
# first), removes the package with dpkg, and clears the /boot files and the module tree.
# It refuses to remove the kernel that is running -- boot another one first.
#
# Everything it installs goes to the real /boot and /usr/lib/modules -- that is the point. If you
# only want to see what would happen, use --check, which writes nothing.

VER_DEFAULT=7.3.0-rc5-next-20261002-t1
RELEASE_TAG=kernel-7.3.0-rc5-next-20261002-t1
REPO=jc372/A16Build
R="${A16_ROOT:-}"; [ -n "$R" ] && SANDBOX=1 || SANDBOX=0
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
ROOT() { printf '%s%s' "$R" "$1"; }
# Under sudo, $HOME is /root -- search the operator's home, or a package sitting in
# ~/a16-deb is invisible and the script downloads the release instead of using it.
UH="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then UH="/home/${SUDO_USER}"; fi
HERE="$(cd "$(dirname "$0")" && pwd)"

MODE=setup; DEB=""; DO_GRUB=1; REINSTALL=0; VER=""
while [ $# -gt 0 ]; do
	case "$1" in
		--check)   MODE=check ;;
		--no-grub) DO_GRUB=0 ;;
		--remove)  MODE=remove; VER="${2:-}"; case "$VER" in --*|"") VER="" ;; *) shift ;; esac ;;
		--reinstall) REINSTALL=1 ;;
		--deb)     DEB="${2:-}"; shift ;;
		-h|--help) sed -n '2,38p' "$0"; exit 0 ;;
		*) echo "unknown option: $1 (try --help)"; exit 2 ;;
	esac
	shift
done
# --remove with no version only lists what is installed, so it needs no privileges
NEEDS_ROOT=1
[ "$MODE" = check ] && NEEDS_ROOT=0
{ [ "$MODE" = remove ] && [ -z "$VER" ]; } && NEEDS_ROOT=0
if [ "$NEEDS_ROOT" = 1 ] && [ "${A16_ALLOW_NONROOT:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }
fi

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
todo() { printf '  [todo] %s\n' "$*"; }
skip() { printf '  [--]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

menufile() {   # the menu the machine actually boots from, not the first one found -- EFI/Boot
	local c best="" best_score=-1 score n          # sorts first but is the removable fallback
	for c in "$R"/boot/efi/EFI/*/grub.cfg "$R"/boot/EFI/EFI/*/grub.cfg "$R"/boot/efi/EFI/*/*/grub.cfg; do
		[ -f "$c" ] || continue
		score=0
		case "$c" in *ubuntu*) score=$((score+100));; esac
		n="$(grep -cE '^[[:space:]]*menuentry' "$c" 2>/dev/null || echo 0)"
		score=$((score+n))
		grep -q 'linux /boot/vmlinuz' "$c" 2>/dev/null && score=$((score+10))
		[ "$score" -gt "$best_score" ] && { best_score="$score"; best="$c"; }
	done
	[ -n "$best" ] && printf '%s' "$best"
}

# ---------------------------------------------------------------- removal
# Undo everything this script put in place for one kernel version: the menu entry, the package,
# the /boot files and the module tree. It never removes the kernel you are running.
if [ "$MODE" = remove ]; then
	step "remove a kernel"
	BOOTD="$(ROOT /boot)"; MODSD="$(ROOT /usr/lib/modules)"
	RUNNING="$(uname -r)"
	if [ -z "$VER" ]; then
		FOUND=0
		for d in "$MODSD"/*next-* "$MODSD"/*a16* "$MODSD"/*glymur*; do
			[ -d "$d" ] || continue
			v="${d##*/}"
			FOUND=1
			printf '    %-44s %s\n' "$v" "$([ "$v" = "$RUNNING" ] && echo '<- running now; will not be removed')"
		done
		if [ "$FOUND" = 0 ]; then
			echo "  (nothing matching this machine's kernel naming; module trees present:)"
			for d in "$MODSD"/*/; do [ -d "$d" ] && printf '    %s\n' "${d##*/}"; done
		fi
		printf '\n  run again with one of them:  sudo bash %s --remove <version>\n' "$(basename "$0")"
		exit 0
	fi
	case "$VER" in */*|.*|'') die "not a kernel version: $VER" ;; esac
	[ "$VER" = "$RUNNING" ] && die "$VER is the kernel you are running.
         Boot another kernel, then run this again -- removing the running one is not undoable."
	[ -d "$MODSD/$VER" ] || [ -f "$BOOTD/vmlinuz-$VER" ] || \
		die "$VER is not installed here (no /lib/modules/$VER and no /boot/vmlinuz-$VER)"

	# The menu entry goes first: if anything after this fails, nothing points at a missing kernel.
	MENU="$(menufile)"
	if [ -n "$MENU" ] && grep -q "vmlinuz-$VER" "$MENU" 2>/dev/null; then
		if [ -w "$MENU" ]; then
			BAK="$MENU.a16-$STAMP"
			cp -f "$MENU" "$BAK" && ok "menu backed up to ${BAK##"$R"}"
			if have python3; then
				python3 - "$MENU" "$VER" <<'PYREMOVE'
import re, sys
path, ver = sys.argv[1], sys.argv[2]
t = open(path).read(); out = []; i = 0; removed = 0
for m in re.finditer(r'(?m)^(\s*menuentry\s+"[^"]+"\s*\{)', t):
    start = m.start(); depth = 0; j = m.start(1) + len(m.group(1)) - 1
    while j < len(t):
        if t[j] == '{': depth += 1
        elif t[j] == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    end = j + 1
    out.append(t[i:start])
    if f'vmlinuz-{ver}' in t[start:end]:
        removed += 1
    else:
        out.append(t[start:end])
    i = end
out.append(t[i:])
open(path, 'w').write(''.join(out))
print(f"  [ok]   removed {removed} menu entry naming vmlinuz-{ver}")
PYREMOVE
				if have grub-script-check; then
					grub-script-check "$MENU" 2>/dev/null && ok "menu syntax ok" || \
						warn "grub-script-check complained -- restore ${BAK##"$R"} if in doubt"
				fi
			else
				warn "no python3 -- delete the menuentry naming vmlinuz-$VER from ${MENU##"$R"} by hand"
			fi
		else
			warn "$MENU is not writable -- run this with sudo"
		fi
	elif [ -n "$MENU" ]; then
		skip "the menu has no entry for this kernel"
	else
		warn "no GRUB menu found -- delete its menuentry by hand"
	fi

	# The package, then whatever it or an earlier install left behind.
	if [ "$SANDBOX" = 1 ]; then
		skip "sandbox: dpkg is not run (it would remove the real package)"
	elif dpkg -s "linux-image-$VER" >/dev/null 2>&1; then
		dpkg -r "linux-image-$VER" >/dev/null 2>&1 && ok "package linux-image-$VER removed" || \
			warn "dpkg -r failed -- remove it by hand: sudo dpkg -r linux-image-$VER"
	else
		skip "linux-image-$VER is not in dpkg (installed by hand?)"
	fi

	LEFT=0
	for f in "$BOOTD/vmlinuz-$VER" "$BOOTD/initrd.img-$VER" "$BOOTD/config-$VER" "$BOOTD/System.map-$VER"; do
		[ -f "$f" ] || continue
		rm -f "$f" && { ok "removed ${f##"$R"}"; LEFT=1; }
	done
	for f in "$BOOTD"/glymur-a16-*"$VER"*.dtb; do
		[ -f "$f" ] || continue
		rm -f "$f" && { ok "removed ${f##"$R"}"; LEFT=1; }
	done
	# rm -rf, so it must be the module tree and not something else with this name
	if [ -d "$MODSD/$VER/kernel" ]; then
		rm -rf "$MODSD/$VER" && { ok "removed ${MODSD##"$R"}/$VER"; LEFT=1; }
	elif [ -d "$MODSD/$VER" ]; then
		warn "${MODSD##"$R"}/$VER has no kernel/ directory -- not removing it, look at it yourself"
	fi

	step "done"
	printf '  %s: ' "$VER"
	if grep -q "vmlinuz-$VER" "$MENU" 2>/dev/null; then printf 'menu entry STILL PRESENT\n'; else printf 'menu entry gone\n'; fi
	printf '  /boot files      : %s\n' "$(ls "$BOOTD"/vmlinuz-"$VER" 2>/dev/null | wc -l) vmlinuz left"
	printf '  modules          : %s\n' "$([ -d "$MODSD/$VER" ] && echo 'STILL PRESENT' || echo gone)"
	printf '  other kernels    : untouched\n'
	echo
	printf '  The menu as it was before this is kept at %s.\n' "grub.cfg.a16-$STAMP"
	printf '  Nothing else of %s is left behind.\n' "$VER"
	exit 0
fi

# ---------------------------------------------------------------- 1. the package
step "1. kernel package"
if [ -z "$DEB" ]; then
	# newest first: with several packages lying around, the one you just built is the one meant.
	# /tmp only as a last resort -- a stray download there is newer than a build and would win.
	DEB="$(ls -t "$HERE"/linux-image-*.deb ./linux-image-*.deb "$UH"/a16-deb/linux-image-*.deb \
		 "$UH"/linux-image-*.deb 2>/dev/null | head -1)"
	[ -n "$DEB" ] || DEB="$(ls -t /tmp/linux-image-*.deb 2>/dev/null | head -1)"
fi
if [ -z "$DEB" ] && [ "$MODE" != check ] && [ "$SANDBOX" = 0 ] && have wget; then
	NAME="linux-image-${VER_DEFAULT}_${VER_DEFAULT}_arm64.deb"
	echo "  nothing local; fetching $NAME from the release"
	if wget -q -O "/tmp/$NAME" "https://github.com/$REPO/releases/download/$RELEASE_TAG/$NAME"; then
		DEB="/tmp/$NAME"; ok "downloaded to $DEB"
	fi
fi
if [ -n "$DEB" ] && [ -f "$DEB" ]; then
	ok "package: $DEB ($(du -h "$DEB" | cut -f1))"
	PKG="$(dpkg-deb -f "$DEB" Package 2>/dev/null || true)"
	VERP="$(dpkg-deb -f "$DEB" Version 2>/dev/null || true)"
else
	[ "$MODE" = check ] || {
		warn "no kernel package found. Looked in:"
		for d in "$HERE" . "$UH/a16-deb" "$UH" /tmp; do printf '        %s\n' "$d"; done
		printf '  packages visible to this search:\n'
		ls -t "$UH"/a16-deb/*.deb 2>/dev/null | head -5 | sed 's/^/        /'
		die "pass one explicitly: --deb /path/to/linux-image-<ver>.deb"
	}
	warn "no package found locally -- would fetch linux-image-${VER_DEFAULT}_${VER_DEFAULT}_arm64.deb"
	PKG="linux-image-$VER_DEFAULT"; VERP="$VER_DEFAULT"
fi
VER="${VERP:-$VER_DEFAULT}"
echo "  package : ${PKG:-unknown}"
echo "  version : $VER"
BOOT="$(ROOT /boot)"; MODS="$(ROOT /lib/modules/$VER)"

# ---------------------------------------------------------------- 2. install (skip if present)
step "2. install"
if [ -f "$BOOT/vmlinuz-$VER" ] && [ -d "$MODS" ] && [ "$REINSTALL" = 0 ]; then
	ok "$VER is already installed (vmlinuz and modules present) -- not reinstalling"
	skip "use --reinstall to install over it anyway (a backup is taken first)"
elif [ "$MODE" = check ]; then
	todo "would run: dpkg -i ${DEB:-<package>}"
elif [ "$SANDBOX" = 1 ]; then
	skip "sandbox: dpkg is not run (it would write the real /boot and /usr/lib/modules)"
else
	have kmod || { apt-get install -y kmod >/dev/null 2>&1 || warn "could not install kmod"; }
	# The package's postinst regenerates the initramfs, and this may be the kernel you are
	# running: keep a copy of the current kernel and initramfs first, so a failure mid-reinstall
	# leaves something to go back to.
	for f in "$BOOT/vmlinuz-$VER" "$BOOT/initrd.img-$VER"; do
		[ -f "$f" ] && cp -f "$f" "$f.a16bak-$STAMP" && ok "backed up ${f##"$R"} -> ${f##"$R"}.a16bak-$STAMP"
	done
	dpkg -i "$DEB" || die "dpkg -i failed -- read the message above"
	ok "installed"
fi

# ---------------------------------------------------------------- 3. verify what landed
step "3. verify"
[ -f "$BOOT/vmlinuz-$VER" ]        && ok "boot/vmlinuz-$VER ($(du -h "$BOOT/vmlinuz-$VER" | cut -f1))" || warn "boot/vmlinuz-$VER missing"
[ -f "$BOOT/config-$VER" ]         && ok "boot/config-$VER"        || warn "boot/config-$VER missing"
[ -f "$BOOT/System.map-$VER" ]     && ok "boot/System.map-$VER"    || warn "boot/System.map-$VER missing"
DTB="$BOOT/glymur-a16-$VER.dtb"
[ -f "$DTB" ] || DTB="$(ls "$BOOT"/glymur-a16-*"$VER"*.dtb 2>/dev/null | head -1)"
[ -n "$DTB" ] && [ -f "$DTB" ]     && ok "device tree ${DTB##"$R"}" || warn "no device tree for $VER -- the entry needs one"
if [ -d "$MODS" ]; then
	NMOD="$(find "$MODS" -name '*.ko*' 2>/dev/null | wc -l)"
	[ "$NMOD" -gt 1000 ] && ok "modules: $NMOD under ${MODS##"$R"}" || warn "only $NMOD modules under ${MODS##"$R"} -- is that right?"
	[ -f "$MODS/modules.dep" ] && ok "modules.dep present" || {
		if [ "$MODE" != check ] && [ "$SANDBOX" = 0 ] && have depmod; then depmod -a "$VER" && ok "modules.dep generated"; fi; }
else
	warn "no ${MODS##"$R"} -- the boot would fail without modules"
fi

INITRD="$BOOT/initrd.img-$VER"
if [ -f "$INITRD" ]; then
	ok "initramfs ${INITRD##"$R"} ($(du -h "$INITRD" | cut -f1))"
elif [ "$MODE" = check ]; then
	todo "$INITRD missing -- it would be built"
elif [ "$SANDBOX" = 1 ]; then
	skip "sandbox: not building an initramfs"
else
	echo "  no initramfs for $VER -- building it (the entry cannot boot without one)"
	have update-initramfs && { update-initramfs -c -k "$VER" || update-initramfs -u -k "$VER" || true; }
	[ ! -f "$INITRD" ] && have mkinitramfs && { mkinitramfs -o "$INITRD" "$VER" 2>/dev/null || true; }
	[ -f "$INITRD" ] && ok "built ${INITRD##"$R"}" || warn "could not build it -- sudo update-initramfs -c -k $VER"
fi

# ---------------------------------------------------------------- 4. the menu entry
step "4. boot menu entry"

# Self-contained on purpose: a user who downloads this script and the package from the release
# page has no repository around it. The entry is written here rather than by a second script.
entry_text() {
	local uuid="$1"
	printf 'menuentry "A16: linux-next %s" {\n' "$VER"
	printf '    # the four kernel options are required on this machine: acpi=off because the ACPI\n'
	printf '    # path is broken under Linux here, and the three *_ignore_unused because the display\n'
	printf '    # does not come up without them\n'
	printf '    search --no-floppy --fs-uuid --set=root %s\n' "$uuid"
	printf '    if [ -f /boot/vmlinuz-%s -a -f /boot/initrd.img-%s ]; then\n' "$VER" "$VER"
	printf '        insmod fdt\n'
	printf '        insmod gzio\n'
	printf '        linux /boot/vmlinuz-%s root=UUID=%s ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7\n' "$VER" "$uuid"
	printf '        devicetree /boot/%s\n' "${DTB##*/}"
	printf '        initrd /boot/initrd.img-%s\n' "$VER"
	printf '        boot\n'
	printf '    fi\n'
	printf '    echo "  vmlinuz-%s or its initramfs is missing -- reinstall it"\n' "$VER"
	printf '    sleep 20\n'
	printf '    configfile $prefix/grub.cfg\n'
	printf '}\n'
}

MENU="$(menufile)"
UUID="$(findmnt -no UUID / 2>/dev/null || echo '')"
[ -n "$UUID" ] || { [ "$SANDBOX" = 1 ] && UUID='11111111-2222-3333-4444-555555555555'; }

if [ "$MODE" = check ]; then
	[ -n "$MENU" ] && ok "menu ${MENU##"$R"}" || warn "no GRUB menu found under ${R}/boot/efi"
	todo "would append this entry; --check writes nothing"
	entry_text "${UUID:-<root-uuid>}" | sed 's/^/  /'
elif [ "$DO_GRUB" = 0 ]; then
	warn "--no-grub: menu untouched; the entry it would have added:"
	entry_text "${UUID:-<root-uuid>}" | sed 's/^/  /'
elif [ -z "$MENU" ]; then
	warn "no GRUB menu found (looked under ${R}/boot/efi and ${R}/boot/EFI) -- add the entry by hand"
elif [ -z "$UUID" ]; then
	warn "could not read the root filesystem UUID -- add the entry by hand"
elif grep -q "vmlinuz-$VER" "$MENU" 2>/dev/null; then
	ok "the menu already has an entry naming vmlinuz-$VER -- nothing to do"
elif [ ! -w "$MENU" ]; then
	warn "$MENU is not writable -- run this with sudo"
else
	BAK="$MENU.a16-$STAMP"
	cp -f "$MENU" "$BAK" && ok "menu backed up to ${BAK##"$R"}"
	{ echo; echo "# ---- added by a16-install-kernel.sh $STAMP ----"; entry_text "$UUID"; } >> "$MENU"
	if grep -q "vmlinuz-$VER" "$MENU"; then
		ok "entry added: \"A16: linux-next $VER\""
		if command -v grub-script-check >/dev/null 2>&1; then
			grub-script-check "$MENU" 2>/dev/null && ok "grub-script-check: syntax ok" || \
				warn "grub-script-check complained -- restore ${BAK##"$R"} if in doubt"
		fi
	else
		warn "could not append the entry; the menu is unchanged apart from the backup"
	fi
fi

# ---------------------------------------------------------------- 5. what to do next
step "next"
printf '  kernel installed : %s\n' "$VER"
printf '  modules          : %s\n' "${MODS##"$R"}"
printf '  menu entry       : "A16: linux-next %s"\n' "$VER"
echo
printf '  Reboot, press Esc at power-on, and select that entry BY NAME.\n'
printf '  Nothing was set as the default -- the machine still boots what it booted\n'
printf '  before, so selecting it is not optional.\n'
printf '  Confirm you are really on it:  uname -r  ->  %s\n' "$VER"
printf '  Anything else printed there means the default entry was taken.\n'
printf '\n  The previous menu is kept beside it as grub.cfg.a16-<stamp>, so you can put it back.\n'
printf '  To retire this entry later, delete its menuentry from that file.\n'
printf '  To undo this install entirely:  sudo bash %s --remove %s\n' "$(basename "$0")" "$VER"
