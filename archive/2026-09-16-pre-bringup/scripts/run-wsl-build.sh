#!/usr/bin/env bash
# Run the A16 kernel build and/or host-selected desktop image build locally.
# Run from a Linux shell (including WSL), not from Windows PowerShell.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-wsl-build.sh [kernel|gui|both|ubuntu-baseline|opensuse-tumbleweed] [options]

Options:
  --repo PATH          Existing A16Build checkout (default: current directory)
  --work-dir PATH      linux-next, build output, and ccache location
                       (default: <repo>/local-wsl-build)
  --ref REF            linux-next ref/SHA to build. Branch (master), daily
                       snapshot tag (next-YYYYMMDD), or a SHA already present
                       in the local clone.
                       (default: master)
  --profile PROFILE    Kernel config profile: known-good, defconfig, or fedora
                       (default: known-good)
  --ubuntu-series NAME Ubuntu daily-live series to build from, e.g. resolute
                       (26.04 LTS) or stonking (default: from config/build.env)
  --iso PATH           Local openSUSE Tumbleweed ARM64 ISO for the
                       opensuse-tumbleweed build (for example ~/openSUSE-Tumbleweed-DVD-aarch64-Snapshot20260802-Media.iso)
  --latest             Use linux-next master and Fedora kernel config; Fedora
                       hosts also use newest Rawhide (Ubuntu always uses daily)
  --jobs N             Parallel compiler jobs (default: all available cores)
  --split-size SIZE    Split the final image into SIZE-sized parts (for example 1900m)
  --keep-output N      Keep N newest generated image/bundle files (default: 2)
  --no-install         Do not install missing Fedora or Ubuntu/Debian build packages
  -h, --help           Show this help

Examples:
  ./scripts/run-wsl-build.sh both --repo ~/src/A16Build
  ./scripts/run-wsl-build.sh ubuntu-baseline --ubuntu-series stonking
  ./scripts/run-wsl-build.sh kernel --ref "$(grep ^KNOWN_GOOD_LINUX_NEXT_REVISION config/build.env | cut -d= -f2)"
  ./scripts/run-wsl-build.sh both --ubuntu-series resolute --jobs 12
  ./scripts/run-wsl-build.sh opensuse-tumbleweed --iso ~/openSUSE-Tumbleweed-DVD-aarch64-Snapshot20260802-Media.iso

The default intentionally tracks current linux-next master so new Glymur/A16
enablement is picked up as it lands. Reproduce the previous pinned baseline
with `--ref $KNOWN_GOOD_LINUX_NEXT_REVISION` from config/build.env. Current
USB image, firmware, packaging and GRUB improvements are always used.

GUI mode creates Fedora media on Fedora hosts and an Ubuntu ARM64 daily live
ISO on Ubuntu/Debian hosts. It never writes a physical disk or alters UEFI.

ubuntu-baseline is Ubuntu/Debian-only. It downloads the configured Ubuntu
daily ISO and creates a verified, byte-for-byte identical output without
building linux-next or modifying the kernel, initramfs, GRUB, or Stubble.

opensuse-tumbleweed builds an openSUSE Tumbleweed ARM64 (aarch64) installer
ISO from a local openSUSE ARM64 ISO plus the custom A16 kernel bundle. It
rebuilds the embedded EFI System Partition's GRUB configuration and never
writes a physical disk or alters UEFI.
EOF
}
MODE=both
case "${1:-}" in
  kernel|gui|both|ubuntu-baseline|opensuse-tumbleweed) MODE="$1"; shift ;;
  ''|--*) ;;
  *) echo "Unknown mode: $1" >&2; usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO/config/build.env"
source /etc/os-release
BUILD_HOST_OS="${ID:-unknown}"
# The openSUSE Tumbleweed build only remasters an ISO from a prebuilt kernel
# bundle, so it is allowed on an openSUSE host without the Fedora/Ubuntu kernel
# toolchain. Every other mode still requires Fedora/Ubuntu/Debian.
case "$BUILD_HOST_OS" in
  opensuse*|tumbleweed) ;;
  fedora|ubuntu|debian) ;;
  *)
    echo "Unsupported host OS: ${PRETTY_NAME:-$BUILD_HOST_OS}. Fedora, Ubuntu, Debian, and openSUSE Tumbleweed are supported." >&2
    exit 2
    ;;
esac
WORK_DIR=""
# Track current linux-next master so new Glymur/A16 enablement is picked up as
# it lands. Reproduce the old pinned baseline with:
#   --ref "$(grep ^KNOWN_GOOD_LINUX_NEXT_REVISION config/build.env | cut -d= -f2)"
REF=master
PROFILE=known-good
UBUNTU_SERIES=""
OPENSUSE_ISO=""
LATEST=0
JOBS="$(nproc)"
SPLIT_SIZE=""
KEEP_OUTPUT=2
INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --ubuntu-series) UBUNTU_SERIES="$2"; shift 2 ;;
    --iso) OPENSUSE_ISO="$2"; shift 2 ;;
    --latest) REF=master; PROFILE=fedora; LATEST=1; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --split-size) SPLIT_SIZE="$2"; shift 2 ;;
    --keep-output) KEEP_OUTPUT="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

REPO="$(cd "$REPO" && pwd)"
[[ -f "$REPO/scripts/build.sh" && -f "$REPO/scripts/make-fedora-xfce-usb-image.sh" && -f "$REPO/scripts/make-ubuntu-desktop-usb-iso.sh" ]] || {
  echo "--repo must point to an A16Build checkout" >&2; exit 2;
}
# Re-source after --repo in case a different checkout was selected.
source "$REPO/config/build.env"
# A per-build --ubuntu-series overrides the series chosen in build.env.
if [[ -n "$UBUNTU_SERIES" ]]; then
  UBUNTU_DAILY_SERIES="$UBUNTU_SERIES"
fi
# Some shells/pastes pass --ref as '"<sha>"' (embedded quotes) or as a
# command-substitution that leaves surrounding quotes intact. Strip any
# leading/trailing double or single quotes so the ref resolves cleanly.
REF="${REF%\"}"; REF="${REF#\"}"
REF="${REF%\'}"; REF="${REF#\'}"
WORK_DIR="${WORK_DIR:-$REPO/local-wsl-build}"
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
TREE="$WORK_DIR/linux-next"
OUT="$WORK_DIR/out"
KERNEL_OUT="$WORK_DIR/kernel-out"
CCACHE_DIR="$WORK_DIR/ccache"
BUILT_BUNDLE=""

if [[ "$MODE" == ubuntu-baseline && "$BUILD_HOST_OS" != ubuntu && "$BUILD_HOST_OS" != debian ]]; then
  echo "ubuntu-baseline must run on an Ubuntu or Debian host" >&2
  exit 2
fi

if [[ "$INSTALL" == 1 ]]; then
  case "$BUILD_HOST_OS" in
    opensuse*|tumbleweed)
      # The openSUSE build only remasters an installer ISO from a prebuilt
      # kernel bundle; it needs the image-manipulation tools available in
      # Tumbleweed, not the cross-compiler/b4 kernel toolchain.
      BUILD_PACKAGES=(xorriso mtools cpio rpm zstd xz curl coreutils findutils gzip grep sed gawk tar)
      case "$MODE" in
        opensuse-tumbleweed) ;;
        *) BUILD_PACKAGES+=(bc bison flex openssl-devel elfutils-devel gcc gcc-aarch64-linux-gnu make dtc ccache python3 perl git) ;;
      esac
      sudo zypper --non-interactive install --no-recommends "${BUILD_PACKAGES[@]}"
      ;;
    fedora)
      BUILD_PACKAGES=(
        bc bison flex gawk openssl-devel elfutils-libelf-devel gcc gcc-aarch64-linux-gnu
        make dtc xz zstd pipx curl ccache pv rpm cpio kmod parted dracut btrfs-progs
        tar findutils coreutils grep sed util-linux systemd python3 perl git
      )
      case "$(uname -m)" in
        aarch64|arm64) ;;
        *) BUILD_PACKAGES+=(qemu-user-static-aarch64) ;;
      esac
      sudo dnf install -y "${BUILD_PACKAGES[@]}"
      ;;
    ubuntu|debian)
      if [[ "$MODE" == ubuntu-baseline ]]; then
        BUILD_PACKAGES=(curl xorriso binutils coreutils grep gawk findutils)
      else
        BUILD_PACKAGES=(
          bc bison flex libssl-dev libelf-dev gcc-aarch64-linux-gnu
          device-tree-compiler xz-utils zstd pipx curl ccache pv rpm2cpio cpio kmod parted
          dracut-core btrfs-progs tar findutils coreutils grep sed util-linux systemd python3 perl git
          xorriso initramfs-tools-core gzip
        )
        case "$(uname -m)" in
          aarch64|arm64) ;;
          *) BUILD_PACKAGES+=(qemu-user-binfmt) ;;
        esac
      fi
      sudo apt-get update
      sudo apt-get install -y "${BUILD_PACKAGES[@]}"
      ;;
    *)
      echo "Unsupported host OS for automatic dependency installation: ${ID:-unknown}. Use --no-install after installing the required build tools." >&2
      exit 2
      ;;
  esac
fi
export PATH="$HOME/.local/bin:$PATH"

require_tools() {
  local missing=0 tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; missing=1; }
  done
  (( missing == 0 )) || { echo "Install the missing tools or rerun without --no-install." >&2; exit 2; }
}

if [[ "$MODE" == ubuntu-baseline ]]; then
  require_tools bash curl sha256sum cmp cp stat strings xorriso awk grep find sort tail cut split
  BASE="https://cdimage.ubuntu.com/ubuntu/$UBUNTU_DAILY_SERIES/daily-live/current"
  IMAGE="$UBUNTU_DAILY_SERIES-desktop-arm64.iso"
  BASE_URL="$BASE/$IMAGE"
  BASE_IMAGE_SHA256="$(curl -fsSL "$BASE/SHA256SUMS" | awk -v image="$IMAGE" '{name=$2; sub(/^\*/, "", name); if (name == image) {print $1; exit}}')"
  [[ -n "$BASE_IMAGE_SHA256" ]] || { echo "Could not find Ubuntu daily ISO checksum for $IMAGE" >&2; exit 2; }
  echo "Ubuntu ARM64 unchanged baseline: $BASE_URL"
  OUT="$OUT" DOWNLOAD_DIR="$WORK_DIR/downloads" BASE_IMAGE_SHA256="$BASE_IMAGE_SHA256" \
    KEEP_OUTPUT="$KEEP_OUTPUT" SPLIT_SIZE="$SPLIT_SIZE" \
    bash "$REPO/scripts/make-ubuntu-daily-baseline.sh" "$BASE_URL"
  echo "Finished. Outputs are in: $OUT"
  exit 0
fi

COMMON_TOOLS=(bash curl find grep sed awk sort head tail cut sha256sum tar xz zstd pv cpio rpm2cpio)
require_tools "${COMMON_TOOLS[@]}"
if [[ "$MODE" == kernel || "$MODE" == both ]]; then
  require_tools pipx ccache make gcc aarch64-linux-gnu-gcc bc bison flex dtc perl python3
  command -v b4 >/dev/null || pipx install b4
  require_tools b4
fi
if [[ "$MODE" == gui || "$MODE" == both ]]; then
  case "$BUILD_HOST_OS" in
    fedora)
      require_tools depmod lsblk losetup mount mountpoint partprobe udevadm sudo lsinitrd
      [[ -x /usr/sbin/losetup || -x /sbin/losetup || -x "$(command -v losetup)" ]] || {
        echo "losetup must be executable" >&2; exit 2;
      }
      ;;
    ubuntu|debian) require_tools xorriso unmkinitramfs md5sum gzip cmp lsinitramfs split stat strings ;;
  esac
fi

if [[ "$MODE" != opensuse-tumbleweed ]]; then
if [[ ! -d "$TREE/.git" ]]; then
  git clone https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git "$TREE"
fi
echo "A16 kernel baseline: ref=$REF profile=$PROFILE"
if git -C "$TREE" rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1; then
  # Ref is already present in the local clone's history (for example a
  # known-good SHA from the full initial clone). git.kernel.org does not
  # advertise arbitrary SHAs as fetchable refs, so checkout locally.
  git -C "$TREE" checkout --detach "$REF"
elif git -C "$TREE" fetch --depth=1 origin "$REF" 2>/dev/null; then
  # Branch names (master) and daily tags (next-YYYYMMDD) fetch normally.
  git -C "$TREE" checkout --detach FETCH_HEAD
else
  echo "Could not fetch or find linux-next ref: $REF" >&2
  echo "Use a branch name (master), a daily tag (next-YYYYMMDD), or a SHA already in the local clone." >&2
  exit 2
fi
fi

mkdir -p "$OUT" "$CCACHE_DIR"
[[ "$KEEP_OUTPUT" =~ ^[0-9]+$ ]] || { echo "--keep-output must be a non-negative integer" >&2; exit 2; }
prune_output() {
  local -a stale
  mapfile -t stale < <(find "$OUT" -maxdepth 1 -type f \
    \( -name 'zenbook-a16-*.tar.zst' -o -name 'fedora-xfce-a16-*.raw' -o -name 'fedora-xfce-a16-*.raw.xz' -o -name 'ubuntu-desktop-a16-*.iso' -o -name 'opensuse-tumbleweed-a16-*.iso' \) \
    -printf '%T@ %p\n' | sort -nr | tail -n +$((KEEP_OUTPUT + 1)) | cut -d' ' -f2-)
  for artifact in "${stale[@]}"; do
    echo "Pruning older local output: $(basename "$artifact")"
    rm -f -- "$artifact" "$artifact.sha256"
  done
  # Remove checksums left behind by an interrupted or manually removed output.
  while IFS= read -r checksum; do
    [[ -f "${checksum%.sha256}" ]] || rm -f -- "$checksum"
  done < <(find "$OUT" -maxdepth 1 -type f \
    \( -name 'zenbook-a16-*.sha256' -o -name 'fedora-xfce-a16-*.sha256' -o -name 'ubuntu-desktop-a16-*.sha256' -o -name 'opensuse-tumbleweed-a16-*.sha256' \))
}
export CCACHE_DIR
ccache --set-config=max_size=20G

if [[ "$MODE" == kernel || "$MODE" == both ]]; then
  # Never reuse a patched source tree or kernel object directory as a build
  # input. Retain ccache and packaged outputs, which are safe performance
  # caches, but rebuild from the requested pristine linux-next revision.
  echo "Cleaning kernel source tree and object output"
  git -C "$TREE" reset --hard HEAD
  git -C "$TREE" clean -ffdx
  rm -rf "$KERNEL_OUT"
  bash "$REPO/scripts/apply-series.sh" "$TREE"
  OUT="$KERNEL_OUT" JOBS="$JOBS" KERNEL_CONFIG_PROFILE="$PROFILE" \
    BUILD_CC='ccache aarch64-linux-gnu-gcc' BUILD_HOSTCC='ccache gcc' \
    bash "$REPO/scripts/build.sh" "$TREE"
  {
    echo "linux_next_revision=$(git -C "$TREE" rev-parse HEAD)"
    echo "requested_ref=$REF"
    echo "config_profile=$PROFILE"
    echo "known_good_linux_next_revision=$KNOWN_GOOD_LINUX_NEXT_REVISION"
    echo "known_good_repo_revision=$KNOWN_GOOD_REPO_REVISION"
    echo "known_good_fedora_xfce_image_url=$KNOWN_GOOD_FEDORA_XFCE_IMAGE_URL"
    echo "known_good_fedora_xfce_image_sha256=$KNOWN_GOOD_FEDORA_XFCE_IMAGE_SHA256"
  } > "$KERNEL_OUT/a16-build-baseline.txt"
  # Use a separate variable for the artifact destination. In an environment
  # assignment list, DEST="$OUT" can observe the preceding temporary OUT
  # assignment and incorrectly place the bundle beside the kernel objects.
  ARTIFACT_OUT="$OUT"
  OUT="$KERNEL_OUT" DEST="$ARTIFACT_OUT" bash "$REPO/scripts/package.sh" "$TREE"
  BUILT_BUNDLE="$(find "$ARTIFACT_OUT" -maxdepth 1 -type f -name 'zenbook-a16-*.tar.zst' \
    -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
  [[ -n "$BUILT_BUNDLE" ]] || { echo "Packaging completed without a kernel bundle in $ARTIFACT_OUT" >&2; exit 2; }
  prune_output
  ccache --show-stats || true
fi

if [[ "$MODE" == opensuse-tumbleweed ]]; then
  # The openSUSE build needs a kernel bundle and a local openSUSE ARM64 ISO.
  # It does not build linux-next itself, so require an existing bundle.
  BUNDLE="$BUILT_BUNDLE"
  if [[ -z "$BUNDLE" ]]; then
    BUNDLE="$(find "$OUT" "$KERNEL_OUT" -maxdepth 1 -type f -name 'zenbook-a16-*.tar.zst' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  fi
  [[ -n "$BUNDLE" ]] || {
    echo "No A16 kernel bundle found in $OUT or $KERNEL_OUT. Run 'kernel' or 'both' first, or supply one." >&2; exit 2; }
  [[ -n "$OPENSUSE_ISO" ]] || { echo "opensuse-tumbleweed requires --iso <path to openSUSE ARM64 ISO>" >&2; exit 2; }
  [[ -f "$OPENSUSE_ISO" ]] || { echo "openSUSE ISO not found: $OPENSUSE_ISO" >&2; exit 2; }
  require_tools xorriso mcopy mtype rpm2cpio cpio xz
  echo "Using kernel bundle: $BUNDLE"
  echo "Using openSUSE base ISO: $OPENSUSE_ISO"
  OUT="$OUT" DOWNLOAD_DIR="$WORK_DIR/downloads" SPLIT_SIZE="$SPLIT_SIZE" \
    bash "$REPO/scripts/make-opensuse-tumbleweed-usb-iso.sh" "$BUNDLE" "$OPENSUSE_ISO"
  prune_output
fi

if [[ "$MODE" == gui || "$MODE" == both ]]; then
  if [[ "$MODE" == both ]]; then
    # Never substitute an older archive after this invocation built one.
    BUNDLE="$BUILT_BUNDLE"
  else
    # GUI-only mode accepts archives from the buggy earlier launcher, but
    # compares both locations together so the newest valid build wins.
    BUNDLE="$(find "$OUT" "$KERNEL_OUT" -maxdepth 1 -type f -name 'zenbook-a16-*.tar.zst' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  fi
  [[ -n "$BUNDLE" ]] || {
    echo "No kernel bundle found in $OUT or $KERNEL_OUT" >&2; exit 2;
  }
  echo "Using kernel bundle: $BUNDLE"
  case "$BUILD_HOST_OS" in
    fedora)
      if [[ "$LATEST" == 1 ]]; then
        BASE=https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Spins/aarch64/images
        IMAGE="$(curl -fsSL "$BASE/" | grep -oE 'Fedora-Xfce-Disk-Rawhide-[0-9]{8}\.n\.[0-9]+\.aarch64\.raw\.xz' | sort -Vu | tail -n1)"
        [[ -n "$IMAGE" ]] || { echo "Could not find the latest Fedora Xfce ARM64 raw image" >&2; exit 2; }
        BASE_URL="$BASE/$IMAGE"
        BASE_IMAGE_SHA256=""
      else
        BASE_URL="$KNOWN_GOOD_FEDORA_XFCE_IMAGE_URL"
        BASE_IMAGE_SHA256="$KNOWN_GOOD_FEDORA_XFCE_IMAGE_SHA256"
      fi
      echo "Fedora Xfce base image: $BASE_URL"
      if [[ -n "$SPLIT_SIZE" ]]; then
        OUT="$OUT" DOWNLOAD_DIR="$WORK_DIR/downloads" BASE_IMAGE_SHA256="$BASE_IMAGE_SHA256" SPLIT_SIZE="$SPLIT_SIZE" bash "$REPO/scripts/make-fedora-xfce-usb-image.sh" "$BUNDLE" "$BASE_URL"
      else
        OUT="$OUT" DOWNLOAD_DIR="$WORK_DIR/downloads" BASE_IMAGE_SHA256="$BASE_IMAGE_SHA256" COMPRESS=0 bash "$REPO/scripts/make-fedora-xfce-usb-image.sh" "$BUNDLE" "$BASE_URL"
      fi
      ;;
    ubuntu|debian)
      BASE="https://cdimage.ubuntu.com/ubuntu/$UBUNTU_DAILY_SERIES/daily-live/current"
      IMAGE="$UBUNTU_DAILY_SERIES-desktop-arm64.iso"
      [[ -n "$IMAGE" ]] || { echo "Could not find the current Ubuntu ARM64 desktop daily ISO" >&2; exit 2; }
      BASE_URL="$BASE/$IMAGE"
      BASE_IMAGE_SHA256="$(curl -fsSL "$BASE/SHA256SUMS" | awk -v image="$IMAGE" '{name=$2; sub(/^\*/, "", name); if (name == image) {print $1; exit}}')"
      [[ -n "$BASE_IMAGE_SHA256" ]] || { echo "Could not find Ubuntu daily ISO checksum" >&2; exit 2; }
      echo "Ubuntu ARM64 daily base image: $BASE_URL"
      OUT="$OUT" DOWNLOAD_DIR="$WORK_DIR/downloads" BASE_IMAGE_SHA256="$BASE_IMAGE_SHA256" SPLIT_SIZE="$SPLIT_SIZE" \
        bash "$REPO/scripts/make-ubuntu-desktop-usb-iso.sh" "$BUNDLE" "$BASE_URL"
      ;;
  esac
  prune_output
fi

echo "Finished. Outputs are in: $OUT"
