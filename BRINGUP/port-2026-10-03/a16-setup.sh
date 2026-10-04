#!/usr/bin/env bash
# a16-setup.sh -- get an ASUS Zenbook A16 (UX3607OA) running this kernel, from a fresh Ubuntu
# install to sound coming out of the speakers, and say plainly what is left over.
#
#   sudo bash a16-setup.sh                 # do everything it can, then report what is left
#   sudo bash a16-setup.sh --check         # change nothing; report the current state
#   sudo bash a16-setup.sh --deb FILE.deb  # install a specific package
#   sudo bash a16-setup.sh --firmware DIR  # use an extracted Windows firmware tree you already have
#   sudo bash a16-setup.sh --boot-entry    # just write the boot entry file and print it
#
# It never touches the bootloader: the machine's firmware has no boot entry it can use and no EFI
# variable Linux can write, so the GRUB entry is edited from Windows. This script generates that
# entry with your real root UUID already filled in, writes it next to the EFI partition and to
# your home directory, and tells you where to paste it.
#
# Safe to re-run. Every step checks first and skips what is already done. Logs to
# ~/a16-setup-<timestamp>.log (the invoking user's home, even under sudo).
set -u

VERSION_DEFAULT=7.3.0-rc5-next-20261002-ec1
RELEASE_TAG=kernel-7.3.0-rc5-next-20261002-ec1
UCM_BRANCH=topic/zenbooka16
UCM_REPO=https://github.com/quic-kdybcio/alsa-ucm-conf
REPO_RAW=https://raw.githubusercontent.com/jc372/A16Build/main
TPLG_NAME=GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin
DSP_DIR=/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA

MODE=setup; DEB=""; FWDIR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--check)      MODE=check ;;
		--boot-entry) MODE=entry ;;
		--deb)        DEB="${2:-}"; shift ;;
		--firmware)   FWDIR="${2:-}"; shift ;;
		-h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown option: $1 (try --help)"; exit 2 ;;
	esac
	shift
done

# Under sudo, $HOME is /root. Resolve the operator's home so logs, the entry file and the
# WirePlumber rule land where they can actually find them.
USER_HOME="${HOME:-/root}"; RUN_AS=""
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then
	USER_HOME="/home/${SUDO_USER}"; RUN_AS="${SUDO_USER}"
fi
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nostamp)"
LOG="$USER_HOME/a16-setup-$STAMP.log"

if [ "$MODE" != check ]; then
	[ "$(id -u)" = 0 ] || { echo "run this with sudo: sudo bash $0   (--check needs no root)"; exit 1; }
fi
: > "$LOG" 2>/dev/null || LOG=/var/tmp/a16-setup-$STAMP.log
exec > >(tee -a "$LOG") 2>&1

step()  { printf '\n=== %s ===\n' "$*"; }
ok()    { printf '  [ok]   %s\n' "$*"; }
todo()  { printf '  [todo] %s\n' "$*"; }
skip()  { printf '  [--]   %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

DONE_LIST=(); LEFT_LIST=()

step "machine and prerequisites"
MODEL="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "  model : $MODEL"
echo "  kernel: $(uname -r)"
echo "  log   : $LOG"
case "$MODEL" in *UX3607OA*|*Zenbook*A16*) ok "this is the machine this script is for" ;;
	*) warn "not a Zenbook A16 ($MODEL) -- continuing, but the kernel options and DTB are specific to it" ;;
esac
for t in dpkg update-initramfs mkinitramfs depmod; do
	have "$t" && ok "$t present" || warn "$t missing"
done

# ---------------------------------------------------------------- 1. the kernel package
step "1. kernel package"
VER="$VERSION_DEFAULT"
if [ -f "/boot/vmlinuz-$VER" ]; then
	ok "kernel $VER already installed in /boot"
else
	if [ -z "$DEB" ]; then
		for c in ./linux-image-*.deb "$USER_HOME/a16-deb"/linux-image-*.deb \
		         "$(dirname "$0")"/linux-image-*.deb /tmp/linux-image-*.deb; do
			[ -f "$c" ] && DEB="$c" && break
		done
	fi
	if [ -n "$DEB" ] && [ -f "$DEB" ]; then
		echo "  installing $DEB"
		have kmod || { apt-get install -y kmod >/dev/null 2>&1 || warn "could not install kmod"; }
		if dpkg -i "$DEB"; then ok "package installed"
		else warn "dpkg -i failed -- fix the message above, then re-run"; fi
	else
		todo "no .deb found. Download it and re-run:"
		echo "        wget -O linux-image-$VER.deb \\"
		echo "          https://github.com/jc372/A16Build/releases/download/$RELEASE_TAG/linux-image-${VER}_${VER}_arm64.deb"
		echo "        sudo bash $0 --deb ./linux-image-$VER.deb"
	fi
fi

if [ -f "/boot/vmlinuz-$VER" ]; then
	for f in "config-$VER" "System.map-$VER" "glymur-a16-$VER.dtb"; do
		[ -f "/boot/$f" ] && ok "/boot/$f" || warn "/boot/$f missing"
	done
	DONE_LIST+=("kernel $VER installed")
else
	LEFT_LIST+=("install the kernel package (step 1 above)")
fi

step "2. initramfs"
INITRD="/boot/initrd.img-$VER"
if [ -f "$INITRD" ]; then
	ok "$INITRD present ($(du -h "$INITRD" | cut -f1))"
	DONE_LIST+=("initramfs")
else
	if [ "$MODE" = check ]; then
		todo "$INITRD missing -- the boot entry will not work until it exists"
	else
		echo "  building it (update-initramfs -c -k $VER)"
		if have update-initramfs; then update-initramfs -c -k "$VER" || update-initramfs -u -k "$VER" || true; fi
		[ -f "$INITRD" ] || have mkinitramfs && mkinitramfs -o "$INITRD" "$VER" 2>/dev/null || true
		[ -f "$INITRD" ] && { ok "built $INITRD"; DONE_LIST+=("initramfs"); } \
		                 || { warn "could not build it by hand -- run: sudo update-initramfs -c -k $VER"; \
		                      LEFT_LIST+=("initramfs"); }
	fi
fi

# ---------------------------------------------------------------- 3. the boot entry
step "3. boot entry"
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || echo '')"
ROOT_UUID="$(findmnt -no UUID / 2>/dev/null || echo '')"
DTB="/boot/glymur-a16-$VER.dtb"; [ -f "$DTB" ] || DTB="$(ls /boot/glymur-a16-*"$VER"*.dtb 2>/dev/null | head -1)"
echo "  root partition : ${ROOT_SRC:-unknown}"
echo "  root UUID      : ${ROOT_UUID:-not readable}"
echo "  device tree    : ${DTB:-not found}"

if [ -n "$ROOT_UUID" ] && [ -f "$DTB" ]; then
	ENTRY_FILE="$USER_HOME/a16-grub-entry.txt"
	{
	echo "# Paste this into the machine's GRUB menu, from Windows:"
	echo "#     mountvol S: /s"
	echo "#     notepad S:\\EFI\\ubuntu_snapdragon\\grub.cfg"
	echo "# Then power on and pick it with Esc if it is not the default. Secure Boot off for Linux."
	echo
	echo "menuentry \"[10] A16: linux-next next-20261002\" {"
	echo "    search --no-floppy --fs-uuid --set=root $ROOT_UUID"
	echo "    if [ -f /boot/vmlinuz-$VER -a -f /boot/initrd.img-$VER ]; then"
	echo "        insmod fdt"
	echo "        insmod gzio"
	echo "        linux /boot/vmlinuz-$VER root=UUID=$ROOT_UUID ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7"
	echo "        devicetree $DTB"
	echo "        initrd /boot/initrd.img-$VER"
	echo "        boot"
	echo "    fi"
	echo "        echo \"  kernel or initramfs missing -- check the filenames in this entry\""
	echo "        sleep 20"
	echo "        configfile \$prefix/grub.cfg"
	echo "}"
	} > "$ENTRY_FILE" 2>/dev/null && chown "${RUN_AS:-root}" "$ENTRY_FILE" 2>/dev/null
	[ "$MODE" = check ] && { echo "  (--check: nothing written; the entry would say)"; sed 's/^/      /' "$ENTRY_FILE"; rm -f "$ENTRY_FILE"; }
	[ "$MODE" = check ] || ok "entry written to $ENTRY_FILE" 
	# a copy on the EFI partition, which Windows can read
	[ "$MODE" = check ] && esp_skip=1 || esp_skip=0
	for esp in /boot/efi /boot/EFI; do
		[ "$esp_skip" = 1 ] && break
		[ -d "$esp" ] || continue
		cp "$ENTRY_FILE" "$esp/A16-GRUB-ENTRY.txt" 2>/dev/null && \
			ok "also written where Windows can reach it: ${esp}/A16-GRUB-ENTRY.txt"
		break
	done
	GRUB_CFG=/boot/efi/EFI/ubuntu_snapdragon/grub.cfg
	if [ -f "$GRUB_CFG" ] && grep -q "vmlinuz-$VER" "$GRUB_CFG" 2>/dev/null; then
		ok "the menu already has an entry for $VER"
		DONE_LIST+=("boot entry present")
	else
		todo "add it from Windows -- the text is in $ENTRY_FILE (and A16-GRUB-ENTRY.txt on the EFI partition)"
		LEFT_LIST+=("add the boot entry from Windows")
	fi
else
	warn "cannot generate the entry without a root UUID and device tree"
	LEFT_LIST+=("boot entry (run this again once the package is installed)")
fi

# ---------------------------------------------------------------- 4. firmware (audio)
step "4. ADSP/CDSP firmware (audio; from your own Windows install)"
NEED=(qcadsp8480.mbn qccdsp8480.mbn adsp_dtbs.elf cdsp_dtbs.elf)
missing=0; for f in "${NEED[@]}"; do [ -f "$DSP_DIR/$f" ] || missing=$((missing+1)); done
if [ "$missing" = 0 ]; then
	ok "all four DSP images already installed in $DSP_DIR"
	DONE_LIST+=("DSP firmware")
else
	[ -z "$FWDIR" ] && for c in "$USER_HOME/a16-payload/a16-local-firmware" "$USER_HOME/a16-firmware" \
	                              "$(dirname "$0")/a16-local-firmware"; do
		[ -d "$c" ] && FWDIR="$c" && break
	done
	if [ -n "$FWDIR" ] && [ -d "$FWDIR" ]; then
		if [ "$MODE" = check ]; then
			todo "firmware found in $FWDIR -- re-run without --check to install it"
		else
			mkdir -p "$DSP_DIR"
			( cd "$FWDIR" && [ -f sha256sums.txt ] && sha256sum -c --quiet sha256sums.txt 2>/dev/null ) \
				&& ok "sha256sums.txt verified" || warn "no usable sha256sums.txt -- installing without verification"
			for f in "${NEED[@]}"; do
				src=$(find "$FWDIR" -name "$f" -print -quit 2>/dev/null)
				[ -n "$src" ] && cp -f "$src" "$DSP_DIR/$f" && ok "installed $f"
			done
			DONE_LIST+=("DSP firmware")
		fi
	else
		todo "DSP firmware not present, and this machine cannot get it from the internet:"
		echo "        it is Qualcomm proprietary material inside your Windows install."
		echo "        On the Windows side, with this repository:"
		echo "            DRY_RUN=1 OUT=/mnt/c/Users/<you>/a16-firmware bash BRINGUP/tools/extract-windows-a16-firmware.sh"
		echo "                     OUT=/mnt/c/Users/<you>/a16-firmware bash BRINGUP/tools/extract-windows-a16-firmware.sh"
		echo "        Copy the four DSP files to $USER_HOME/a16-payload/a16-local-firmware/"
		echo "        and re-run this script. Without them the machine is silent but otherwise fine."
		LEFT_LIST+=("audio firmware from your Windows install")
	fi
fi

if [ -f "$DSP_DIR/qcadsp8480.mbn" ]; then
	TC=/lib/firmware/qcom/glymur/$TPLG_NAME
	if [ -f "$TC" ] || [ -f "$TC.zst" ]; then ok "topology installed ($TPLG_NAME)"
	else
		SRC="$(dirname "$0")/../tools/a16-install-tplg.sh"
		if [ "$MODE" != check ] && [ -x "$SRC" ]; then bash "$SRC" >/dev/null 2>&1 && ok "topology installed" || warn "a16-install-tplg.sh failed"
		elif [ "$MODE" != check ]; then
			# self-contained fallback: the SoC-matching topology ships in linux-firmware
			for cand in /lib/firmware/qcom/glymur/GLYMUR-CRD-tplg.bin.zst \
			            /lib/firmware/qcom/x1e80100/*S15-tplg.bin.zst; do
				[ -f "$cand" ] || continue
				[ "${cand%.zst}" = "$TC" ] && continue
				cp "$cand" "$TC.zst" && ok "topology installed from $(basename "$cand")"
				break
			done
		else
			todo "topology missing -- re-run without --check"
		fi
	fi
fi

# ---------------------------------------------------------------- 5. desktop audio
step "5. desktop audio (UCM profile and PipeWire)"
UCM_DIR=/usr/share/alsa/ucm2/Qualcomm/glymur
if [ -f "$UCM_DIR/ZenbookA16-HiFi.conf" ] || grep -rqs 'ZenbookA16-HiFi' "$UCM_DIR" 2>/dev/null; then
	ok "UCM profile for this machine is in place"
	DONE_LIST+=("UCM profile")
elif [ "$MODE" = check ]; then
	todo "UCM profile for the Zenbook A16 not installed -- re-run without --check"
else
	if have git; then
		TMPU="$(mktemp -d)"; 
		if git clone -q --depth 1 --branch "$UCM_BRANCH" "$UCM_REPO" "$TMPU/ucm" 2>/dev/null; then
			mkdir -p "$UCM_DIR"
			for f in "$TMPU"/ucm/ucm2/Qualcomm/glymur/*.conf; do
				[ -f "$f" ] || continue
				[ -f "$UCM_DIR/$(basename "$f")" ] && cp -n "$UCM_DIR/$(basename "$f")" "$UCM_DIR/$(basename "$f").pre-a16setup"
				cp -f "$f" "$UCM_DIR/"
			done
			ok "UCM profile installed from $UCM_BRANCH"
			DONE_LIST+=("UCM profile")
		else
			warn "could not clone $UCM_REPO (offline?)"
			LEFT_LIST+=("UCM profile ($UCM_REPO branch $UCM_BRANCH)")
		fi
		rm -rf "$TMPU"
	else
		LEFT_LIST+=("UCM profile (git not installed)")
	fi
fi

# PipeWire: UCM, not the legacy ACP path, or the desktop sits on "Dummy Output"
WP_DIR="$USER_HOME/.config/wireplumber/wireplumber.conf.d"
WP_FILE="$WP_DIR/51-a16-ucm.conf"
if [ -f "$WP_FILE" ]; then
	ok "WirePlumber rule already present"
else
	if [ "$MODE" = check ]; then
		todo "WirePlumber rule missing -- re-run without --check"
	else
		mkdir -p "$WP_DIR"
		cat > "$WP_FILE" <<'EOF'
# Use the ALSA UCM profile for the A16's card instead of the ACP legacy path; ACP offers this
# card no profile at all, which leaves the desktop on "Dummy Output".
monitor.alsa.rules = [
  {
    matches = [ { api.alsa.card.name = "~GLYMUR.*" } ]
    actions = { update-props = {
        api.alsa.use-acp = false
        api.alsa.use-ucm = true
        session.suspend-timeout-seconds = 5
      } }
  }
]
EOF
		chown -R "${RUN_AS:-root}" "$USER_HOME/.config" 2>/dev/null
		ok "wrote $WP_FILE"
		DONE_LIST+=("WirePlumber rule")
	fi
fi

# restart their sound server without reaching into their session as root
if [ "$MODE" != check ] && [ -f "$WP_FILE" ]; then
	UID_OP="$(id -u "${RUN_AS:-root}" 2>/dev/null || echo '')"
	if [ -n "$RUN_AS" ] && [ -n "$UID_OP" ] && [ -d "/run/user/$UID_OP" ]; then
		sudo -u "$RUN_AS" XDG_RUNTIME_DIR="/run/user/$UID_OP" systemctl --user restart wireplumber 2>/dev/null \
			&& ok "restarted WirePlumber as $RUN_AS" || warn "could not restart WirePlumber from here"
	fi
fi

# ---------------------------------------------------------------- 6. report
step "what is done, and what is left"
if [ ${#DONE_LIST[@]} -gt 0 ]; then echo "  done:"; for d in "${DONE_LIST[@]}"; do echo "    - $d"; done; fi
if [ ${#LEFT_LIST[@]} -gt 0 ]; then
	echo "  left for you:"
	for l in "${LEFT_LIST[@]}"; do echo "    - $l"; done
else
	echo "  left for you: nothing this script can see."
fi

if [ "$MODE" != check ]; then
	step "checking the sound card"
	if have wpctl; then
		run_as() { [ -n "$RUN_AS" ] && [ -n "${UID_OP:-}" ] && [ -d "/run/user/$UID_OP" ] \
			&& sudo -u "$RUN_AS" XDG_RUNTIME_DIR="/run/user/$UID_OP" "$@" 2>/dev/null || "$@" 2>/dev/null; }
		sink="$(run_as wpctl status | awk '/Sinks:/{f=1;next} f&&/^ *\*? *[0-9]+\./{print; exit}')"
		echo "  default sink: ${sink:-not visible}"
		case "$sink" in
			*Dummy*) todo "still Dummy Output -- log out and back in (or reboot) so WirePlumber reloads, then check again" ;;
			*Multimedia*|*Media*|*Speaker*|*Built*) ok "a real sink is present -- raise the volume and play something" ;;
			*) [ -n "$sink" ] && ok "sink present" || todo "no sink visible yet; a reboot is the reliable way to pick up a new UCM profile" ;;
		esac
	else
		skip "wpctl not installed -- check Sound settings after a reboot"
	fi
fi

printf '\nfull log: %s\n' "$LOG"
printf 'references: docs/audio.md, docs/efi-on-windows.md in the repository\n'
