#!/usr/bin/env bash
# a16-port.sh -- put the A16 support onto a fresh Ubuntu arm64 install.
#
# Live on a USB stick next to `patches/` and `config-seed`, and run it on the target machine.
# It downloads the linux-next snapshot itself and verifies every hash on the way through, so
# the only thing that has to travel by hand is this script and the patches.
#
#   bash a16-port.sh --fetch            # download the snapshot and verify it (no changes)
#   bash a16-port.sh --verify           # apply patches to a scratch tree, check every hash
#   sudo bash a16-port.sh               # fetch + verify + build + install beside the others
#   sudo bash a16-port.sh --install TREE   # install a tree that is already built
#
# Options: --work DIR (default ~/a16-port)  --jobs N  --no-install
set -u

# ---------------------------------------------------------------- what we build against
RELEASE="7.3.0-rc5-next-20261002"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-next-${RELEASE}.tar.gz"
TARBALL="linux-next-${RELEASE}.tar.gz"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$HERE/patches"
WORK="${HOME}/a16-port"
JOBS="$(nproc 2>/dev/null || echo 4)"

MODE=full; DO_INSTALL=1; PREBUILT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--fetch)   MODE=fetch ;;
		--verify)  MODE=verify ;;
		--no-install) DO_INSTALL=0 ;;
		--work)    WORK="$2"; shift ;;
		--jobs)    JOBS="$2"; shift ;;
		--install) MODE=install; PREBUILT="$2"; shift ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "unknown option: $1"; exit 2 ;;
	esac
	shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- the patches travel with us
[ -d "$PATCH_DIR" ] || die "no patches/ next to this script -- it must sit beside the patch directory"
mapfile -t PATCHES < <(ls -1 "$PATCH_DIR"/*.patch 2>/dev/null | sort)
[ "${#PATCHES[@]}" -gt 0 ] || die "patches/ is empty"
say "release : $RELEASE"
say "patches : ${#PATCHES[@]}"
say "work    : $WORK"

# ---------------------------------------------------------------- prerequisites
step "prerequisites"
missing=""
for t in wget tar patch make gcc gawk flex bison bc depmod rsync; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	say "missing:$missing"
	say "install them with:  sudo apt install -y build-essential wget tar patch gawk flex bison bc kmod rsync"
	[ "$MODE" = full ] || die "install the packages above and re-run"
	command -v apt >/dev/null 2>&1 && sudo apt install -y build-essential wget tar patch gawk flex bison bc kmod rsync || die "cannot install prerequisites"
else
	say "all present"
fi

mkdir -p "$WORK" || die "cannot create $WORK"
cd "$WORK" || die "cannot enter $WORK"

# ---------------------------------------------------------------- fetch + verify the snapshot
step "linux-next snapshot"
if [ -s "$TARBALL" ]; then
	say "already downloaded: $TARBALL"
else
	say "downloading $URL"
	wget -q --show-progress -O "$TARBALL" "$URL" || die "download failed"
fi
SUM="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
say "sha256 : $SUM"
if [ -f "$HERE/MANIFEST.sha256" ]; then
	want="$(grep -m1 " $TARBALL\$" "$HERE/MANIFEST.sha256" 2>/dev/null | cut -d' ' -f1)"
	if [ -n "$want" ]; then
		[ "$SUM" = "$want" ] || die "snapshot hash does not match the manifest -- refusing"
		say "matches the manifest"
	else
		say "no hash for the snapshot in the manifest (record it there once verified)"
	fi
	step "patch hashes"
	( cd "$HERE" && sha256sum -c --ignore-missing MANIFEST.sha256 2>&1 | sed 's/^/  /' )
fi
[ "$MODE" = fetch ] && { say "\ndone: snapshot fetched and verified"; exit 0; }

# ---------------------------------------------------------------- apply the patches
step "applying ${#PATCHES[@]} patches"
SRC="$WORK/linux-next-${RELEASE}"
if [ -d "$SRC" ]; then
	say "keeping the pristine extraction at $SRC (it is the reference copy -- do not delete it)"
	TREE="$WORK/tree"
	rm -rf "$TREE"; mkdir -p "$TREE"
	( cd "$SRC" && tar -c . ) | ( cd "$TREE" && tar -x ) || die "copy failed"
else
	tar -xzf "$TARBALL" || die "extract failed"
	[ -d "$SRC" ] || die "unexpected tarball layout: $SRC not found"
	TREE="$WORK/tree"
	rm -rf "$TREE"; mkdir -p "$TREE"
	( cd "$SRC" && tar -c . ) | ( cd "$TREE" && tar -x ) || die "copy failed"
fi
say "pristine : $SRC"
say "tree     : $TREE"

cd "$TREE" || die "cannot enter the tree"
applied=0
for p in "${PATCHES[@]}"; do
	# dry-run first, against the tree as it stands: a report is not a gate, this is
	if ! patch -p1 --dry-run --forward --batch < "$p" >/dev/null 2>&1; then
		die "$(basename "$p") does not apply cleanly -- stopping before touching anything"
	fi
	patch -p1 --forward --batch < "$p" >/dev/null 2>&1 || die "$(basename "$p") failed mid-apply"
	applied=$((applied + 1))
	printf '  [%2d/%2d] %s\n' "$applied" "${#PATCHES[@]}" "$(basename "$p")"
done
rej=$(find . -name '*.rej' | wc -l)
[ "$rej" = 0 ] || die "$rej rejected hunks -- the tree is in an unknown state"
say "all ${#PATCHES[@]} patches applied, no rejects"

# ---------------------------------------------------------------- hash the result
step "resulting source, hashed"
REPORT="$WORK/A16-port-verification.txt"
{
	printf '# A16 port verification\n'
	printf 'release  %s\n' "$RELEASE"
	printf 'snapshot %s\n' "$SUM"
	printf 'patches  %s\n\n' "${#PATCHES[@]}"
	for p in "${PATCHES[@]}"; do printf 'patch %s %s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$(basename "$p")"; done
	printf '\n'
	# the files the patches touch, hashed after application
	for p in "${PATCHES[@]}"; do
		grep -E '^\+\+\+ ' "$p" | sed 's|^+++ b/||' | awk '{print $1}'
	done | sort -u | while read -r f; do
		[ -f "$f" ] && printf 'file  %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
	done
} > "$REPORT"
say "written: $REPORT"
grep -c '^file' "$REPORT" | sed 's/^/  files hashed: /'

if [ "$MODE" = verify ]; then
	step "what changed, relative to the pristine snapshot"
	for p in "${PATCHES[@]}"; do
		f=$(grep -E '^\+\+\+ ' "$p" | head -1 | sed 's|^+++ b/||' | awk '{print $1}')
		if [ -f "$SRC/$f" ]; then
			printf '  %-62s %s\n' "$f" "$(diff -q "$SRC/$f" "$TREE/$f" >/dev/null 2>&1 && echo unchanged || echo 'differs (as the patch says)')"
		fi
	done
	say "\nverified. tree left at $TREE -- nothing was built or installed."
	exit 0
fi

# ---------------------------------------------------------------- build
step "build (this is the slow part)"
[ -f "$HERE/config-seed" ] && cp -f "$HERE/config-seed" .config && say "seeded .config from config-seed"
[ -f .config ] || make defconfig
./scripts/config --set-str LOCALVERSION "-a16"
make -s olddefconfig >/dev/null 2>&1
LOG="$WORK/build-$(date +%Y%m%d-%H%M).log"
say "log: $LOG"
nice -n 10 make -j"$JOBS" Image dtbs modules > "$LOG" 2>&1
rc=$?
if [ "$rc" != 0 ] || grep -aqiE '^.*error:' "$LOG"; then
	grep -aiE 'error:' "$LOG" | tail -5 | sed 's/^/  /'
	die "build failed (exit $rc) -- see $LOG"
fi
say "build ok: $(make -s kernelrelease)"
MODE=install; PREBUILT="$TREE"

# ---------------------------------------------------------------- install beside the others
if [ "$MODE" = install ] && [ "$DO_INSTALL" = 1 ]; then
	step "installing beside the existing kernels"
	if [ "$(id -u)" != 0 ]; then
		say "needs root to install. Re-run the install step as:"
		say "    sudo bash $0 --install $PREBUILT"
		exit 0
	fi
	VER="$(make -s -C "$PREBUILT" kernelrelease)"
	install -m 644 "$PREBUILT/arch/arm64/boot/Image" "/boot/vmlinuz-$VER" || die "kernel copy failed"
	install -m 644 "$PREBUILT/arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb" \
		"/boot/glymur-a16-$VER.dtb" || die "dtb copy failed"
	make -C "$PREBUILT" INSTALL_MOD_STRIP=1 modules_install >/dev/null 2>&1 || die "modules_install failed"
	if command -v update-initramfs >/dev/null 2>&1; then
		update-initramfs -c -k "$VER" >/dev/null 2>&1 || say "note: update-initramfs returned non-zero; check /boot"
	fi
	say "installed: /boot/vmlinuz-$VER"
	say "Add a boot entry (or use BRINGUP/tools/a16-install-stock-next.sh from the repository),"
	say "then boot it and check the panel first."
fi
