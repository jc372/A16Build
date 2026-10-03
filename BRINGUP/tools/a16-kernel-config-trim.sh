#!/usr/bin/env bash
# a16-kernel-config-trim.sh -- take a linux-next build from Ubuntu's *generic* config to one for
# this machine: everything upstream that this Zenbook A16 can actually use, and nothing for the
# platforms and cards it cannot.  Rationale: the generic arm64 config builds ~440 device trees and
# thousands of drivers across every ARM vendor plus the x86-era PCI world (Adaptec SCSI, AMD/i915/
# VMware GPUs).  Each of those is another thing a three-week-old integration tree can break -- one
# of them (drivers/scsi/aic7xxx) is what stopped the next-20261002 build -- and they are most of the
# build time.
#
#   bash a16-kernel-config-trim.sh plan    <tree>   what would change, no writes
#   bash a16-kernel-config-trim.sh apply   <tree>   edit .config, olddefconfig, VERIFY, report
#
# Nothing here needs root.  The critical-hardware guard is the point of the script: after the trim it
# re-reads the config and ABORTS (restoring the backup) if anything this laptop needs to boot and be
# usable has been disabled.  A trimmed build that boots blind is worse than one that fails to build.
set -u

MODE="${1:-plan}"
TREE="${2:-}"

# ---- what must survive, on pain of restoring the backup --------------------------------------
# soc + platform, panel + its PHYs, the GPU/display stack, the EC (keyboard/touchpad), storage,
# USB (docks, dongles, external disks), Wi-Fi, and the hook Ubuntu needs to boot.
CRITICAL='
CONFIG_ARM64
CONFIG_ARCH_QCOM
CONFIG_MODULES
CONFIG_DRM
CONFIG_DRM_MSM
CONFIG_PHY_QCOM_QMP
CONFIG_PHY_QCOM_EDP
CONFIG_PHY_QCOM_USB_HS
CONFIG_ATH12K
CONFIG_I2C
CONFIG_I2C_QCOM_GENI
CONFIG_PINCTRL
CONFIG_PINCTRL_GLYMUR
CONFIG_HID
CONFIG_INPUT
CONFIG_USB
CONFIG_USB_XHCI_HCD
CONFIG_USB_DWC3
CONFIG_USB_STORAGE
CONFIG_SCSI
CONFIG_NVME_CORE
CONFIG_BLK_DEV_NVME
CONFIG_EXT4_FS
CONFIG_VFAT_FS
CONFIG_EXFAT_FS
CONFIG_FAT_FS
CONFIG_EFI
CONFIG_EFI_STUB
CONFIG_FB
CONFIG_FRAMEBUFFER_CONSOLE
CONFIG_TTY
CONFIG_SERIAL_AMBA_PL011
CONFIG_SPI
CONFIG_SPI_QCOM_GENI
CONFIG_REGULATOR
CONFIG_QCOM_RPMH
CONFIG_MAILBOX
CONFIG_QCOM_SMD_RPM
'

# ---- other ARM64 platforms: their SoCs, their drivers, and above all their device trees --------
# (the single biggest build-time saving: ~440 dtbs -> a few dozen)
PLATFORMS='
CONFIG_ARCH_ACTIONS
CONFIG_ARCH_ALPINE
CONFIG_ARCH_APPLE
CONFIG_ARCH_BITMAIN
CONFIG_ARCH_BCM
CONFIG_ARCH_BCM2835
CONFIG_ARCH_BCM_IPROC
CONFIG_ARCH_BCMBCA
CONFIG_ARCH_BRCMSTB
CONFIG_ARCH_BERLIN
CONFIG_ARCH_LG1K
CONFIG_ARCH_DOVE
CONFIG_ARCH_EXYNOS
CONFIG_ARCH_FREESCALE
CONFIG_ARCH_MXC
CONFIG_ARCH_HISI
CONFIG_ARCH_HPE
CONFIG_ARCH_INTEL_SOCFPGA
CONFIG_ARCH_LAYERSCAPE
CONFIG_ARCH_MARVELL
CONFIG_ARCH_MEDIATEK
CONFIG_ARCH_MESON
CONFIG_ARCH_MMP
CONFIG_ARCH_MSTAR
CONFIG_ARCH_MICROCHIP
CONFIG_ARCH_MVEBU
CONFIG_ARCH_NPCM
CONFIG_ARCH_NVIDIA
CONFIG_ARCH_REALTEK
CONFIG_ARCH_RENESAS
CONFIG_ARCH_ROCKCHIP
CONFIG_ARCH_S32
CONFIG_ARCH_SEATTLE
CONFIG_ARCH_SHMOBILE
CONFIG_ARCH_SPARX5
CONFIG_ARCH_STM32
CONFIG_ARCH_SUNXI
CONFIG_ARCH_SYNQUACER
CONFIG_ARCH_TEGRA
CONFIG_ARCH_TESLA_FSD
CONFIG_ARCH_THUNDER
CONFIG_ARCH_THUNDER2
CONFIG_ARCH_VEXPRESS
CONFIG_ARCH_VIRT
CONFIG_ARCH_XGENE
CONFIG_ARCH_ZYNQMP
'

# ---- GPUs that cannot exist in this chassis ---------------------------------------------------
GPUS='
CONFIG_DRM_AMDGPU
CONFIG_DRM_I915
CONFIG_DRM_NOUVEAU
CONFIG_DRM_QXL
CONFIG_DRM_VMWGFX
CONFIG_DRM_VIRTIO_GPU
CONFIG_DRM_TEGRA
CONFIG_DRM_EXYNOS
CONFIG_DRM_ROCKCHIP
CONFIG_DRM_MEDIATEK
CONFIG_DRM_STI
CONFIG_DRM_PANFROST
CONFIG_DRM_LIMA
'

# ---- SCSI/FibreChannel/RAID HBAs: PCI cards, on a laptop with NVMe ----------------------------
SCSI_HBA='
CONFIG_SCSI_AIC7XXX
CONFIG_SCSI_AIC79XX
CONFIG_SCSI_AIC94XX
CONFIG_SCSI_ARCMSR
CONFIG_SCSI_BFA_FC
CONFIG_SCSI_CHELSIO_FCOE
CONFIG_SCSI_LPFC
CONFIG_SCSI_MPT3SAS
CONFIG_SCSI_MPT2SAS
CONFIG_SCSI_MVSAS
CONFIG_SCSI_PM8001
CONFIG_SCSI_QLA_FC
CONFIG_SCSI_QLA_ISCSI
CONFIG_SCSI_SNIC
CONFIG_SCSI_UFS_QCOM_HCI
CONFIG_SCSI_VIRTIO
CONFIG_SCSI_3W_9XXX
CONFIG_SCSI_3W_SAS
CONFIG_SCSI_ISCI
CONFIG_SCSI_IPS
CONFIG_SCSI_GDTH
CONFIG_SCSI_INITIO
CONFIG_SCSI_NSP32
CONFIG_SCSI_DC395x
CONFIG_SCSI_DMX3191D
CONFIG_SCSI_AM53C974
CONFIG_SCSI_BNX2_ISCSI
CONFIG_SCSI_BNX2X_FCOE
CONFIG_SCSI_CXGB3_ISCSI
CONFIG_SCSI_CXGB4_ISCSI
CONFIG_SCSI_BUSLOGIC
CONFIG_SCSI_SYM53C8XX_2
CONFIG_SCSI_QLOGIC_1280
CONFIG_SCSI_IMM
CONFIG_SCSI_EATA
CONFIG_SCSI_NCR53C8XX
CONFIG_SCSI_ADVANSYS
CONFIG_SCSI_WD719X
CONFIG_SCSI_AHA152X
CONFIG_SCSI_AHA1542
CONFIG_SCSI_AIC7XXX_OLD
CONFIG_SCSI_ESAS2R
CONFIG_SCSI_MYRB
CONFIG_SCSI_MYRS
CONFIG_SCSI_SMARTPQI
CONFIG_SCSI_MPI3MR
'

TOTAL=0
for L in $PLATFORMS $GPUS $SCSI_HBA; do TOTAL=$((TOTAL+1)); done

die() { printf 'FATAL: %s\n' "$*"; exit 1; }
[ -n "$TREE" ] || die "usage: bash a16-kernel-config-trim.sh {plan|apply} <kernel tree>"
[ -f "$TREE/.config" ] || die "no .config in $TREE -- configure the tree first"
[ -x "$TREE/scripts/config" ] || die "no scripts/config in $TREE"

cfg() { grep -m1 "^$1=" "$TREE/.config" 2>/dev/null | cut -d= -f2-; }

printf '=== a16 kernel config trim: %s ===\n' "$MODE"
printf 'tree: %s\n' "$TREE"
printf 'rule: keep everything this machine can use (including USB devices you might plug in),\n'
printf '      drop the platform/GPU/HBA drivers — and their device trees — that cannot appear here.\n\n'

printf '=== critical options present BEFORE (these must survive) ===\n'
missing_before=0
for o in $CRITICAL; do
  v=$(cfg "$o")
  if [ -z "$v" ]; then printf '  %-34s <absent>\n' "$o"; missing_before=$((missing_before+1))
  else printf '  %-34s %s\n' "$o" "$v"; fi
done
printf '  (%s critical options absent from this config to begin with)\n\n' "$missing_before"

count_group() { local n=0; for o in $1; do [ -n "$(cfg "$o")" ] && n=$((n+1)); done; printf '%s' "$n"; }
printf '=== what the trim touches ===\n'
printf '  platforms : %s of %s present, would be disabled\n' "$(count_group "$PLATFORMS")" "$(printf '%s\n' $PLATFORMS | wc -l)"
printf '  GPUs      : %s of %s present, would be disabled\n' "$(count_group "$GPUS")" "$(printf '%s\n' $GPUS | wc -l)"
printf '  HBAs      : %s of %s present, would be disabled\n' "$(count_group "$SCSI_HBA")" "$(printf '%s\n' $SCSI_HBA | wc -l)"
printf '  device trees before: %s\n' "$(find "$TREE/arch/arm64/boot/dts" -name '*.dtb' 2>/dev/null | wc -l)"
printf '  keeping the qcom platform, msm, the panel PHYs, the EC, ath12k, USB, NVMe, ext4/fat/exfat.\n'

if [ "$MODE" != "apply" ]; then
  printf '\nplan only -- nothing written.  Run:  bash %s apply %s\n' "$0" "$TREE"
  exit 0
fi

BAK="$TREE/.config.a16-pre-trim-$(date +%Y%m%d-%H%M%S)"
cp -a "$TREE/.config" "$BAK" || die "could not back up .config"
printf '\nbackup: %s\n' "$BAK"

for o in $PLATFORMS $GPUS $SCSI_HBA; do
  ( cd "$TREE" && ./scripts/config --disable "${o#CONFIG_}" ) 2>/dev/null
done
( cd "$TREE" && make -j"$(nproc)" olddefconfig ) >/dev/null 2>&1 || die "olddefconfig failed (config restored)"

printf '\n=== VERIFY: did anything this machine needs get disabled? ===\n'
fail=0
for o in $CRITICAL; do
  v=$(cfg "$o")
  if [ -z "$v" ]; then printf '  LOST: %s\n' "$o"; fail=1; fi
done
if [ "$fail" != 0 ]; then
  cp -a "$BAK" "$TREE/.config"
  die "a critical option was lost -- .config restored from backup. Report the LOST lines above."
fi
printf '  all %s critical options survived\n' "$(printf '%s\n' $CRITICAL | grep -c .)"
printf '\n=== result ===\n'
printf '  device trees now: %s\n' "$(find "$TREE/arch/arm64/boot/dts" -name '*.dtb' 2>/dev/null | wc -l)"
printf '  qcom dtbs kept  : %s\n' "$(find "$TREE/arch/arm64/boot/dts/qcom" -name '*.dtb' 2>/dev/null | wc -l)"
printf '  trim applied.  Rebuild with:\n'
printf '    cd %s && nice -n 19 ionice -c3 make -j6 Image dtbs modules\n' "$TREE"
