#!/usr/bin/env bash
# a16-install-kernel.sh -- install an A16 kernel package (image, modules, device tree), find out
# what version it is, put it in the boot menu, and tell you what to select after rebooting.
#
#   sudo bash a16-install-kernel.sh                 # newest linux-image-*.deb it can find, or fetch it
#   sudo bash a16-install-kernel.sh --deb FILE.deb  # a specific package (e.g. one you just built)
#   sudo bash a16-install-kernel.sh --check         # report what it would do; changes nothing
#   sudo bash a16-install-kernel.sh --no-grub       # install only; write the entry out as text
#   sudo bash a16-install-kernel.sh --reinstall     # install over a version already present
#
# Every command this script runs is in this script. It calls only tools already on the machine --
# dpkg, depmod, update-initramfs, grub-script-check -- plus one sibling script, a16-grub-entry.sh,
# which adds the menu entry. The only thing it fetches is the kernel package, and only when it
# cannot find one locally (--deb, or beside itself, or in ~/a16-deb).
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
#
# What it does, in order:
#   1. finds the package -- beside itself, in ~/a16-deb, in /tmp, or from the GitHub release
#   2. reads the version out of the package, and skips the install if that version is already
#      there (--reinstall forces it, after backing up what it is about to replace)
#   3. installs it with dpkg (kmod first if it is missing)
#   4. verifies every file listed above, runs depmod, and builds the initramfs if the package's
#      postinst did not -- an entry without an initramfs cannot boot, and that is the most common
#      failure on this machine
#   5. adds the boot menu entry via a16-grub-entry.sh, which backs the menu up first and refuses
#      to add a duplicate
#   6. prints the version, what went where, and exactly what to pick after rebooting
#
# Everything it installs goes to the real /boot and /usr/lib/modules -- that is the point. If you
# only want to see what would happen, use --check, which writes nothing.

VER_DEFAULT=7.3.0-rc5-next-20261002-ec1
RELEASE_TAG=kernel-7.3.0-rc5-next-20261002-ec1
REPO=jc372/A16Build
R="${A16_ROOT:-}"; [ -n "$R" ] && SANDBOX=1 || SANDBOX=0
ROOT() { printf '%s%s' "$R" "$1"; }
# Under sudo, $HOME is /root -- search the operator's home, or a package sitting in
# ~/a16-deb is invisible and the script downloads the release instead of using it.
UH="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then UH="/home/${SUDO_USER}"; fi
HERE="$(cd "$(dirname "$0")" && pwd)"

MODE=setup; DEB=""; DO_GRUB=1; REINSTALL=0
while [ $# -gt 0 ]; do
	case "$1" in
		--check)   MODE=check ;;
		--no-grub) DO_GRUB=0 ;;
		--reinstall) REINSTALL=1 ;;
		--deb)     DEB="${2:-}"; shift ;;
		-h|--help) sed -n '2,26p' "$0"; exit 0 ;;
		*) echo "unknown option: $1 (try --help)"; exit 2 ;;
	esac
	shift
done
if [ "$MODE" != check ] && [ "${A16_ALLOW_NONROOT:-0}" != 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash $0"; exit 1; }
fi

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
todo() { printf '  [todo] %s\n' "$*"; }
skip() { printf '  [--]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die()  { printf '  [fail] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

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
[ -n "$DTB" ] && [ -f "$DTB" ]     && ok "device tree ${DTB##"$R"}" || warn "no device tree for $VER -- the entry needs one (--dtb for a16-grub-entry.sh)"
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
ENTRY_TOOL="$HERE/a16-grub-entry.sh"
if [ "$MODE" = check ]; then
	todo "would add the entry for $VER (a16-grub-entry.sh add $VER)"
elif [ ! -f "$ENTRY_TOOL" ]; then
	warn "a16-grub-entry.sh is not beside this script -- adding it by hand is not covered here"
else
	ARGS=(add)
	[ "$DO_GRUB" = 0 ] && ARGS+=(--no-grub)
	[ -n "$DTB" ] && [ -f "$DTB" ] && ARGS+=(--dtb "$DTB")
	ARGS+=("$VER")
	A16_ALLOW_NONROOT=1 bash "$ENTRY_TOOL" "${ARGS[@]}"
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
printf '\n  After it boots and you are happy with it, clear the dead entries:\n'
printf '      sudo bash %s/a16-grub-prune.sh --apply\n' "${HERE##"$R"}"
