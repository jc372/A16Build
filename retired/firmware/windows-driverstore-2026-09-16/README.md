# Windows-side firmware for the ASUS Zenbook A16 (UX3607OA)

Extracted **2026-09-16** from the machine's own Windows 11 ARM64 installation
(`C:\Windows\System32\DriverStore\FileRepository`) with
`scripts/extract-windows-a16-firmware.sh`. SoC: **Snapdragon X2 Elite Extreme
X2E94100** — Glymur, SoC id `8480`, which is why every Qualcomm driver package
on this machine is named `*8480`.

| | |
|---|---|
| files copied | 326 |
| size | 87 MiB |
| duplicates skipped | 17 (identical hashes across driver-package versions) |
| already in this repo | 4 (the ADSP/CDSP images, see below) |
| integrity | `sha256sum -c sha256sums.txt` → 326 OK |

The installed Linux system is missing Wi-Fi, sound and HDMI, and the vendor blobs
for those blocks exist only on the Windows side. This directory is that payload,
plus the mapping from driver package to the hardware it actually serves.

## Hardware this machine reports, and the package bound to it

Read from Windows (`Win32_PnPSignedDriver` + `Get-PnpDevice -PresentOnly`,
2026-09-16). The mapping to a DriverStore package is verified, not guessed: the
`C:\Windows\INF\oem<NN>.inf` copy was hashed and matched against the package's own
`.inf` (identical sha256 → same file).

| device (as Windows names it) | instance | bound INF | DriverStore package |
|---|---|---|---|
| FastConnect C7700 NCM820A Wi-Fi 7 adapter, 685.13804.110.0 | `PCI\VEN_17CB&DEV_1112&SUBSYS_E14F105B` | `oem177.inf` | `qcwlancol8480.inf_arm64_d440e12aca6ddc77` |
| FastConnect C7700 NCM820A Bluetooth adapter, 685.13804.30.0 | `QCA_SHB\UART_H4_CLG\3&14B65D69&0&4097` | `oem138.inf` | `qcbtaddvscregistry8480…` (registry/AVDS extension; BT payload is in `qcbluetooth8480`) |
| Adreno X2-90 GPU, 32.0.172.1 | `ACPI\VEN_QCOM&DEV_0F36` | `oem153.inf` | `qcdx8480.inf_arm64_33cc9319e871e878` |
| Aqstic ACX Audio Device / Static Endpoints, 685.13804.40.6 | `AUCD\VEN_QCOM&DEV_0FCD`, `QCASD\VEN_QCOM&DEV_0FCD` | `oem142.inf` | `qcasd8480` |
| Aqstic SoundWire Controller, 685.13804.70.0 | `ADCM\VEN_QCOM&DEV_0FF6` | `oem66.inf` | `qcascd8480` |
| Aqstic Audio DSP and Calibration Manager | `ADSP\VEN_QCOM&DEV_0F22` | `oem81.inf` | `qcadcm8480` |
| Aqstic ACX Audio Device | `AUCD\VEN_QCOM&DEV_0FCD` | `oem106.inf` | `qcaucd8480` |
| Aqstic AudioDriverX | `ADCM\VEN_QCOM&DEV_0FF4` | `oem6.inf` | `qcadx8480` |
| Audio DSP / Compute DSP / Control Processor / Secure Processor subsystems | `ACPI\QCOM0F1B`, `QCOM0FA6`, `QCOM1036`, `QCOM0F8D` | `oem9.inf` | `qcsubsys8480` (base subsys driver; the ADSP payload is `qcsubsys_ext_adsp8480`) |
| I2C Bus Device ×6 | `ACPI\QCOM0F10\<n>` | `oem155.inf` | `qci2c8480` |
| Spectra ISP camera stack | `ACPI\QCOM0F25`, `QCOM0F32`, `QCOM0F33`, `VEN_QCOM&DEV_0F98/0F99/0F06/0FEC` | `oem76/58/132/119/101.inf` | `qccamisp8480`, `qccamauxsensor8480`, `qccamfrontsensor8480`, `qccamavs8480`, `qcalwaysonsensing8480` |
| Display Services | `SWD\DRIVERENUM\{480B97A2-…}` | `oem43.inf` | `qcdpps8480` |

Notes on the rest of the display path: the panel is `DISPLAY\SDC422C`
("MyASUS_Splendid"), driven by the Adreno GPU package; there is **no separate
HDMI/DisplayPort bridge driver package** on this machine, so HDMI comes out of the
GPU/display block plus the DP controller (and HDCP, below). The SoundWire SDCA
endpoints (`SOUNDWIRE\SDCA_*`, `MAN_0217`) are served by Microsoft's
`sdcaclass.inf` / `sdcaaggregator.inf`, not by a vendor package.

## Wi-Fi is QCC2072-class, not WCN7850 — read this before chasing firmware

Two WLAN packages are staged in this DriverStore. Only one is this machine's part:

- **Bound and used:** `qcwlancol8480` → PCI **17CB:1112**, BDFs named
  `bdwlan_qcc2072_1p0_ncm820A*.elf`, firmware `wlanfw.bin`, `phy_ucode.elf`,
  `aux_ucode.elf`, `regdb.bin`, `Data.msc`.
- **Staged but bound to nothing present:** `qcwlanhmt8480` — the **WCN785x**
  family (`bdwlan_wcn785x_2p0_ncm825*/ncm865a*`, `wlanfw20.mbn`, `phy_ucode20.elf`).
  Kept here as reference only. Earlier project notes described the A16's Wi-Fi as
  "ath12k/WCN7850"; that came from this staged package, not from the hardware.

What linux-next already has (checked in `local-wsl-build/linux-next`, `next-20260914`):

- `drivers/net/wireless/ath/ath12k/wifi7/pci.c` carries
  `#define QCC2072_DEVICE_ID 0x1112` in `ath12k_wifi7_pci_id_table[]`, a
  QCC2072-specific window register address, `ATH12K_HW_QCC2072_HW10`, and hw
  params whose firmware directory is **`QCC2072/hw1.0`** (`board_size` 256 KiB,
  `m3_loader = ath12k_m3_fw_loader_driver`, `download_aux_ucode = true` — which is
  why the Windows package ships `aux_ucode.elf`).
- So the blob path the driver will look for is `ath12k/QCC2072/hw1.0/`. The Windows
  files are the source material for it (`wlanfw.bin` = the firmware image,
  `bdwlan*.elf` = board/BDF data, `regdb.bin` = regulatory database,
  `phy_ucode.elf`/`aux_ucode.elf` = ucode), not drop-in filenames.
- **linux-firmware may already ship this part — check before converting anything.**
  The `ath-20260812` linux-firmware pull request ("update the QCC2072 hw1.0 firmware
  to WLAN.COL.1.0.c2-00228") carries `ath12k/QCC2072/hw1.0/firmware-2.bin`
  (7,148,724 B in that revision). Reported from the mailing-list pull request and the
  driver's own `QCC2072/hw1.0` directory name, **not** verified against a distro
  package here. So the first Wi-Fi check on the A16 is whether
  `/lib/firmware/ath12k/QCC2072/hw1.0/` exists and how old the linux-firmware package
  is — if it is there, the Windows blobs are irrelevant and the remaining gap is the
  device tree.
- QCC2072-specific hw params in that tree (read from `hw.c`), useful when the DT is
  written: `rfkill_pin/cfg/on_level = 0` (no RFKILL command is sent — this chip ties
  RF-kill to `WLAN_EN` instead of a GPIO), `iova_mask = 0`, `bdf_addr_offset = 0`,
  `supports_aspm = true`, `dp_primary_link_only = false` (multi-link allowed, unlike
  WCN7850), `download_aux_ucode = true`, `m3_loader = ath12k_m3_fw_loader_driver`.
- The A16 device tree has **no Wi-Fi node**: `glymur-asus-zenbook-a16-ux3607oa.dts`
  includes `glymur.dtsi` only, while the CRD/HP/Lenovo boards carry
  `wifi@0 { compatible = "pci17cb,1107"; … }` (1107 = WCN7850). A node with the
  right compatible (`pci17cb,1112`), its supplies and its PCIe root port is the
  missing piece on the Linux side — the gap is in the DT, not solely in the blob.

## Layout

| group | size | what it is |
|---|---|---|
| `wlan/` | 34 MiB | C7700/NCM820A payload (`qcwlancol8480`, two versions) + the staged WCN785x package (`qcwlanhmt8480`): firmware images, all `bdwlan*.elf` board variants (incl. the per-OEM `…_UX3407Q.elf`), `regdb.bin`, `Data.msc` |
| `camera/` | 27 MiB | Spectra ISP: `CAMERA_ICP*.mbn/.elf`, secure-ISP `bm5a75v08s13n*.bin`, per-sensor tuning (`com.qti.tuned.*.bin`, `com.qti.sensormodule.*.bin`) |
| `gpu-video/` | 17 MiB | Adreno/`qcdx` payload: `qcav1e8480.mbn` (AV1 encoder), `qcvss8480.mbn` (video subsystem), `evass.mbn` (EVA), `qcdxkmbase8480*.bin` |
| `adsp/` | 3.1 MiB | audio-DSP payload that is *not* already in the repo: `qcadsprpc`, Aqstic codec managers, plus `acdb_cal.acdb` (the machine's audio calibration database) and `ADCMResources.bin` from `qcacsp_crd8480` |
| `cdsp/` | 2.8 MiB | `qcnspmcdm` extras beyond the already-committed CDSP image |
| `platform/` | 2.1 MiB | `qc*8480` platform packages: `dax3_ext_qc` (≈23 `AUCD_DEV_…xml` audio endpoint definitions), `plutonqc`, watchdog, etc. |
| `display-hdcp/` | 1.3 MiB | `qctreeextqcom8480`: `hdcp1.mbn`, `hdcp2p2.mbn`, `hdcpsrm.mbn`, `pr_3_wp.mbn` — the only display-adjacent firmware on the machine |
| `bluetooth/` | 592 KiB | `hmtbtfw20.tlv`/`hmtnv20.*` (HMT) and `clnbtfw10.tlv`/`clnbtnv10.*` (CLN) patchram + NVM variants, `bsrc_bt.bin` |
| `sensors/` | 508 KiB | `qcsensorsconfigcrd8480` sensor/registry config (JSON + platform files) |
| `host-inventory/` | 90 KiB | not payload: `windows-device-inventory.txt` — the full `Get-PnpDevice`/`Win32_PnPSignedDriver` dump (every present ACPI/PCI device, class, status, instance id, bound INF) that the mapping table above was derived from, plus the PowerShell that produced it |

Each file keeps its original driver-package directory name under its group, so
`qcwlancol8480.inf_arm64_d440e12aca6ddc77/` inside `wlan/` is directly traceable to
the Windows package in the table above.

## Already in this repo (not duplicated)

`firmware/qcom/glymur/ASUSTeK/UX3607OA/{qcadsp8480.mbn, adsp_dtbs.elf, qccdsp8480.mbn,
cdsp_dtbs.elf}` hash-match the Windows files byte for byte; `MANIFEST.tsv` records
those four with status `already-in-repo firmware/qcom/…` instead of copying them
again. That confirms the existing four files came from the same source.

## What is deliberately NOT here

- Driver code: `*.sys *.inf *.cat *.dll *.exe`.
- The Hexagon **userspace module trees** `ADSP/`, `CDSP/`, `HTP/` (`*.so`, `*.so.1`,
  `fastrpc_shell_*` — e.g. `ADSP/libc++.so.1`, `ADSP/libaptXAdaptive*.so`, QNN skels).
  These are Windows-side userspace libraries, not loadable firmware images. ~40 MiB.
- Windows **AI models**: `qcacsp_crd8480/…fai__*.pmd` (~13 MiB each; two packages'
  worth ≈ 150 MiB).
- GPU compiler libraries: `qcgpuarm64compilercore.so` (88 MiB × 2 packages).

To take them anyway:

    INCLUDE_DSP_MODULES=1 SRC=/mnt/c/Windows/System32/DriverStore/FileRepository \
      OUT=firmware/windows-driverstore-2026-09-16-dsp \
      bash scripts/extract-windows-a16-firmware.sh

(the `*.so*` and `*.pmd` exclusions for the AI models/GPU compilers are in the
script's `EXCLUDE_EXT`; widen it there if a specific `.so` is wanted.)

## First checks on the Linux side (exact commands)

Run these in the installed session **before** building anything around these blobs —
they decide which of the three gaps (firmware, driver, device tree) is the real one.
`scripts/a16-triage.sh` in the repo already collects all of it into one tarball
(`sudo bash scripts/a16-triage.sh`, writes to the stick); by hand:

    lspci -nn | grep -i 17cb            # is the Wi-Fi part on the bus at all, and as what?
    lspci -nnk -s <bdf>                 # which driver bound to it
    dmesg | grep -iE 'ath12k|qcc2072'   # probe/firmware errors
    ls -la /lib/firmware/ath12k/QCC2072/hw1.0/ 2>&1   # does the distro firmware ship it?
    ls /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/    # ADSP/CDSP images (DT-path audio)
    cat /proc/device-tree/compatible 2>/dev/null; cat /proc/cmdline   # DT path or ACPI?

Reading the answers:

- **No `17cb` PCI device** → the Wi-Fi block is not being brought up by the DT at all
  (this install boots ACPI mode with Ubuntu's own `7.2.0-5-generic`), so the gap is the
  device tree / PCIe root port, not a blob.
- **Device present, `ath12k` bound, firmware errors in dmesg** → check
  `/lib/firmware/ath12k/QCC2072/hw1.0/`; update `linux-firmware` before reaching for
  the Windows files.
- **`/lib/firmware/ath12k/QCC2072/hw1.0/` present and the driver still fails** → the
  BDF is the suspect, and that is what `wlan/bdwlan*.elf` here is for.
- Note the installed kernel is the distro's, not this repo's linux-next build; whether
  it contains the QCC2072 support at all is unverified (the tree that has it is
  `next-20260914`, in `local-wsl-build/linux-next` on the build side only).

## Verify, reproduce, refresh

    ( cd firmware/windows-driverstore-2026-09-16 && sha256sum -c sha256sums.txt )

`MANIFEST.tsv` columns: `group`, `package`, `file`, `bytes`, `sha256`, `status`
(`copied` | `duplicate-of <path>` | `already-in-repo <path>`), `source`
(full Windows path). Every hash in both files was computed **from the Windows
source file**, and `sha256sums.txt` was regenerated from the copies, so a passing
`sha256sum -c` proves the copies are byte-identical to the originals — including
through the `/mnt/c` mount, which has silently corrupted large files in this
project before.

Dry run (list only, copy nothing):

    DRY_RUN=1 OUT=/tmp/fw bash scripts/extract-windows-a16-firmware.sh

Re-run after a Windows driver update with a new `OUT` date-stamped directory; the
script skips duplicates by content hash and reports everything it changes.

## Status of the claims here

- **Verified on the machine:** the device list, the bound INFs and their hash match
  to DriverStore packages, the file inventory, and every sha256.
- **Read from the tree, not from hardware:** the ath12k `QCC2072` support and the
  A16 DTS having no Wi-Fi node (`local-wsl-build/linux-next`, `next-20260914`).
- **Not verified at all:** that these blobs make Wi-Fi/audio/HDMI work on the Linux
  side. Nothing has been tested against them yet.

## Redistribution

These are vendor binaries (Qualcomm / ASUS / Microsoft) taken from this machine's
own Windows installation. This repository is **private**
(`api.github.com/repos/jc372/A16Build` → 404 unauthenticated), which is what makes
committing them reasonable; keep it private.
