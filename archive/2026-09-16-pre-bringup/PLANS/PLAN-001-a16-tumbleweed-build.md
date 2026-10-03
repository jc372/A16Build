# PLAN-001 — A16 Tumbleweed Build

- **Plan:** PLAN-001
- **Title:** openSUSE Tumbleweed ARM64 live-ISO build for the ASUS Zenbook A16
- **Status:** IN PROGRESS
- **Last updated:** 2026-08-16
- **Owner:** handoff doc — any AI or human can continue from here

---

## 1. Objective

Add a NEW openSUSE Tumbleweed ARM64 build to this repo (`jc372/A16Build`)
that remasters an official Tumbleweed ARM64 DVD ISO into bootable media for
the ASUS Zenbook A16 UX3607OA (Snapdragon X2 Elite "Glymur"): inject the
custom Glymur kernel + DTB, rebuild the installer initramfs with the custom
kernel modules and Qualcomm firmware, and add A16 GRUB entries — **without
touching the existing Fedora/Ubuntu builds**.

End-to-end success = a real A16 kernel bundle + the real Tumbleweed ISO run
through the script inside a Tumbleweed machine (VirtualBox VM `tw-a16`), and
the output boots on the actual A16 hardware.

## 2. Background (overall project)

- Zenbook A16 UX3607OA runs on Snapdragon X2 Elite "Glymur".
- Custom kernel baseline is PINNED while boot problems are isolated:
  - linux-next revision `3d08ff75a47a3e7e2ab45a3bcab6723b4d906422`
  - release `7.2.0-rc7-next-20260810-g3d08ff75a47a`
- Builds run locally in WSL (`/home/jc/A16Build`), **not** GitHub Actions.
  On the openSUSE host the script skips the kernel clone/build and uses
  `zypper` for native tools. (Repo is cloned on macOS at `~/projects/A16Build`
  for coordination; do not run the kernel build there.)
- Secure Boot is disabled whenever Linux is tested on the A16.
- Known-good distro media: Ubuntu ARM64 daily and Tumbleweed snapshot
  20260802 both boot the A16 to a GUI (with external keyboard/mouse).

## 3. Key technical facts (established, don't re-derive)

**Boot path**
- **ACPI mode is the confirmed working path.** DTB-based boot historically
  failed (white dot → black screen). Stock distro kernels boot the same way
  (Ubuntu `7.0.0-14-generic`, Tumbleweed `7.1.5-1-default`).
- Custom kernel must use **48-bit VA/PA**:
  `CONFIG_ARM64_VA_BITS_48=y`, `CONFIG_ARM64_PA_BITS_48=y`,
  `# CONFIG_ARM64_VA_BITS_52 is not set`, same for PA. 52-bit breaks boot.
- Display: Qualcomm display takeover must be deferred —
  `CONFIG_DRM_MSM=m`, `CONFIG_DRM_PANEL_EDP=m`, `CONFIG_DRM_SIMPLEDRM=y`,
  `CONFIG_FRAMEBUFFER_CONSOLE=y`, `# CONFIG_FB_EFI is not set`.
  Diagnostic entries also blacklist MSM so simpledrm/fbcon keeps early output.
- The Tumbleweed ISO kernel is a raw ARM64 `Image` in an EFI application
  wrapper (like the custom kernel). Stub/zboot is NOT required to enter the
  kernel on this hardware.

**openSUSE ARM64 DVD layout (Snapshot20260802, 4.0 GB)**
- GRUB config lives on a FAT EFI System Partition whose IMAGE is the El Torito
  boot file at `/boot/aarch64/efi` INSIDE the ISO9660 tree. UEFI firmware
  boots via that El Torito image.
- Remaster method: modify the ESP grub.cfg, then map the modified ESP as
  `/boot/aarch64/efi` in xorriso. **No separate dd-ESP step** — xorriso drops
  the appended MBR isohybrid partition; El Torito is the path the A16 uses.
- Installer kernel/initrd: `/boot/aarch64/linux` + `/boot/aarch64/initrd`.
  The initrd is XZ→cpio and contains `/dev` device nodes; non-root cpio
  cannot mknod — tolerate those failures.
- A16 DTB path used: `/boot/aarch64/glymur-asus-zenbook-a16-ux3607oa.dtb`.

**Peripherals (upstream gaps, NOT build regressions)**
- Broken on the custom kernel AND on stock Ubuntu/Tumbleweed:
  - Wi-Fi: Qualcomm FastConnect 7800 (WCN7850) → `ath12k`. Firmware added to
    initramfs; untested on TW yet. Closest to working.
  - Trackpad: `i2c-hid`/`hid-multitouch` — needs I2C enumeration check.
  - Internal keyboard: behind the embedded controller, no mainline driver —
    hardest, likely upstream-blocked.

## 4. Current tasks

- [x] Install Tumbleweed (CLI-only) in the ARM VM and enable SSH access
- [x] In guest: install `xorriso mtools cpio rpm zstd xz curl`
- [x] Use a REAL A16 kernel bundle from Ubuntu WSL
- [x] Run the remaster script against a real ARM64 Tumbleweed ISO and verify
      its final SHA-256
- [ ] Boot the output ISO on the actual A16 → confirm kernel+DTB bring-up
- [x] Commit + push branch `feature/tumbleweed-a16-live-iso`
      (committed `3fc5a40`, pushed 2026-08-15; PR suggestion URL on GitHub)
- [x] Recover and integrate the four available UX3607OA ADSP/CDSP firmware blobs
- [ ] Obtain genuine `soccp.mbn` and `soccp_dtb.mbn` from the device SPI-NOR firmware partition

## 5. History

- **2026-08-16 — Firmware investigation and integration (full chronology).**
  1. Searched the physical A16 Windows DriverStore for the DTS-requested names and Qualcomm SoCCP payloads. Recovered `qcadsp8480.mbn`, `adsp_dtbs.elf`, `qccdsp8480.mbn`, and `cdsp_dtbs.elf` from signed ADSP/CDSP driver directories; staged them under `/home/jc/a16-local-firmware/qcom/glymur/ASUSTeK/UX3607OA/`.
  2. The local SoCCP package contained only `RSCP.bin`, `soccpr.jsn`, an INF, and a catalog. A whole-DriverStore search found no `soccp.mbn` or `soccp_dtb.mbn`. `RSCP.bin` is 1,117 bytes and must not be renamed or used as either firmware image.
  3. Found the already-downloaded official ASUS Qualcomm BSP in the Windows Downloads directory (three duplicates). Verified one copy against the published SHA-256 and transferred it to the Ubuntu ARM64 VM; do not download it again unless the version changes.
  4. Installed `7zip` on the Ubuntu VM and unpacked the Windows executable without running it. The extracted BSP was 1.5 GB and reproduced the same SoCCP content—no SoCCP `.mbn`, `.elf`, or DTB blob. Its UTF-16 INF says SoCCP firmware is copied from the laptop SPI-NOR ("spinor") partition at build time. This is why further Windows-package searching was stopped.
  5. Added the four verified ADSP/CDSP files to this repository and changed the Tumbleweed remaster script to require and inject them. Commit `8830aaa` (`tumbleweed: include A16 DSP firmware`) was pushed to `feature/tumbleweed-a16-live-iso`. Script syntax and all hashes passed; no new full ISO build was started because the separate Tumbleweed VM build was already in progress.

- **2026-08-16 — A16 proprietary DSP firmware staged and SoCCP source clarified.** Four files recovered from the Windows DriverStore on the physical UX3607OA are checked into `firmware/qcom/glymur/ASUSTeK/UX3607OA/` and are copied by the Tumbleweed remaster script into both the installer initramfs and the ISO firmware payload:
  - `qcadsp8480.mbn` — SHA-256 `67b4e129d4d60fccd05d85be3754168f46535549a03a3627c598d634e73df49d`
  - `adsp_dtbs.elf` — SHA-256 `7906466c734b2f360d48cf086f80b6e04d84e9b02255c74545aa28d5df1e932c`
  - `qccdsp8480.mbn` — SHA-256 `acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794`
  - `cdsp_dtbs.elf` — SHA-256 `9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d`
  These match the filenames requested by `arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dts`. They were not present in the Fedora firmware RPM used by the remaster script.

  The official ASUS UX3607OA Qualcomm Board Support Package `V1.312.4500.0` was verified with SHA-256 `E8F2389AC5D4DFD30A1A8481EC3C1E282F24BAEA2898414351D0B6EB1FA8A0B3` and fully unpacked on a separate Ubuntu ARM64 VM. It confirms that the Windows SoCCP package contains only `RSCP.bin`, `soccpr.jsn`, an INF, and a catalog: it does **not** contain `soccp.mbn` or `soccp_dtb.mbn`. The INF says the SoCCP-related firmware is copied from the device SPI-NOR ("spinor") partition at build time. Therefore neither missing filename may be synthesized by renaming `RSCP.bin`; doing so would be invalid. Obtain the genuine signed images from SPI-NOR before enabling/testing the SoCCP remote processor. No credentials are recorded in this repository.

  Handoff state: Ubuntu ARM64 VM has the verified BSP and its full extraction under `/home/codex/a16-firmware/`; `7zip` is installed there. The WSL build checkout is `/home/jc/A16Build`; local source artifacts remain in `/home/jc/a16-local-firmware/`. To validate a new Tumbleweed ISO after this commit, use the existing real bundle and snapshot with disk-backed `TMPDIR` as documented below. Do not disturb the separate Tumbleweed VM build while it is running.

- **2026-08-15 (late evening)** — Real build completed in the Tumbleweed ARM
  VM (`192.168.60.179`, user `codex`) using the Ubuntu WSL real bundle
  `zenbook-a16-7.2.0-rc7-next-20260810-g3d08ff75a47a.tar.zst` and
  `openSUSE-Tumbleweed-DVD-aarch64-Snapshot20260806-Media.iso`. Installed
  `xorriso` and `mtools`; reused matching cached Fedora Rawhide Qualcomm and
  Atheros firmware RPMs from Ubuntu WSL. The successful command was:
  `TMPDIR=/home/codex/a16-tmp OUT=/home/codex/a16-output bash scripts/make-opensuse-tumbleweed-usb-iso.sh /home/codex/a16-input/zenbook-a16-7.2.0-rc7-next-20260810-g3d08ff75a47a.tar.zst /home/codex/a16-input/openSUSE-Tumbleweed-DVD-aarch64-Snapshot20260806-Media.iso`.
  It produced a 4,904,321,024-byte ISO with SHA-256
  `08ceb8e868e9e020bce27cd28b14ad968022ef440709056aee2c3504a8d2ccb9`.
  Added `xorriso_sorry_ok` so the script accepts xorriso's exit 32 warning
  when the requested ISO payload was extracted successfully; all later
  byte-for-byte and content verification remains mandatory.
- **2026-08-15 (evening)** — Coordination loop set up:
  - GitHub issue #3 opened as the cross-machine tracker for this plan
    (objective, status, executor sites, next steps).
  - Cron watcher "A16Build PLAN-001 watcher" on the macOS coordinator: every
    4h, monitor-mode (silent unless this plan file changes on origin), pings
    Telegram with a change summary. Runs on `tencent/hy3:free` (OpenRouter)
    to keep cost at zero; verify with `hermes cron list` / job `631d6646dbd4`.
  - AIShare vault `tasks/` reduced to a project registry (repo → plan
    location); plan content lives only in this repo. AGENTS.md at repo root
    points agents at PLANS/.
- **2026-08-15 (afternoon)** — Tumbleweed build committed + pushed to GitHub:
  `3fc5a40` on new remote branch `feature/tumbleweed-a16-live-iso` (run-wsl-build
  mode + `--iso`, remaster script, baseline script, CI workflow; all 3 scripts
  pass `bash -n`). Branch contained origin/main before push; no rebase needed.
  Plan moved from the shared Obsidian vault into this repo (`PLANS/`) so it
  travels with the project; vault keeps only a registry pointer. Added
  `AGENTS.md` so any agent working in the repo follows the plan protocol.
- **2026-08-15 (morning)** — VM `tw-a16` brought up and running in VirtualBox,
  booted from the ORIGINAL untouched ISO (verified byte-identical; all
  experiments were on copies in `~/tw-install/`). Config: EFI, 6 GB RAM,
  2 CPUs, 40 GB disk, NAT, SSH forward host:2222→guest:22. VM sat at the
  installer, waiting for a manual GUI install. The temporary HTTP server from
  the abandoned AutoYaST experiment was stopped.
- **2026-08-14 (evening)** — Tumbleweed build added additively (script +
  baseline script + launcher mode + CI workflow) on branch
  `feature/tumbleweed-a16-live-iso`. Discovered the openSUSE ARM ESP layout.
  Ran the build end-to-end against the REAL user ISO with a synthetic A16
  bundle → exits 0, structurally correct 4.5 GB ISO (kernel/initrd/DTB mapped,
  initramfs carries custom modules + WCN7850 firmware, ESP grub.cfg has A16
  DTB/rescue/ACPI entries). Fixed 8 macOS portability bugs in the script.
  VM `tw-a16` created by a subagent (timed out before boot; UARTs left
  disabled due to arm64 serial-syntax issues). Status saved to
  `/Users/agentb/A16Build-tumbleweed-status.md` (superseded by this plan).
- **2026-08-14 (earlier, main mission)** — ACPI-mode GUI boot achieved on the
  Ubuntu build (the Tumbleweed build inherits this knowledge). Fixed the
  FETCH_HEAD reset bug in `scripts/run-wsl-build.sh` launcher (local `--ref`
  checkout path never fetches → `FETCH_HEAD` undefined; reset against `HEAD`
  instead). Pushed as `742cbb4`. Master-regression bisect deferred.

## 6. What worked

- **Build script verified end-to-end** against the real Tumbleweed ISO with a
  synthetic bundle: exits 0, produces valid 4.5 GB ISO, all structure checks
  pass (kernel/initrd/DTB mapped, initramfs contents, ESP entries, checksum).
  Output artifact (macOS scratch): `/tmp/tw-test/out/opensuse-tumbleweed-a16-6.17.0-a16test-va48-tumbleweed-20260802-modular-drm-live-media.iso`
- **ACPI boot path** confirmed working on the A16 with the custom kernel
  (GUI boots; matches stock distro behavior).
- **48-bit VA/PA + deferred MSM DRM + simpledrm/fbcon** configuration fixes
  the white-dot/black-screen problem.
- **Live filesystem fix**: adding ISO9660/SquashFS/overlay/VirtioSCSI built-ins
  to the initramfs lets casper find the squashfs.
- **Launcher reset fix** (`reset --hard HEAD` + `clean -ffdx`) — verified in a
  scratch repo: leftover patch commits get detached and the tree restores
  pristine to the target SHA.
- **A16 ADSP/CDSP firmware recovery** — the Windows DriverStore artifacts
  matched the DTS filenames and their hashes after staging and after Git add.
  The remaster script now requires all four files before rebuilding the initrd,
  and places them in both the installer firmware tree and the remastered ISO
  firmware payload.

## 7. What failed / gotchas

1. **52-bit VA/PA addressing** → white dot then black screen. Fixed with
   48-bit VA/PA (matches stock distro kernels).
2. **MSM DRM / eDP panel eager takeover** erased early console output → make
   them modules, use simpledrm + framebuffer console, blacklist MSM in
   diagnostic entries.
3. **Live filesystem not found** in Ubuntu initramfs → casper needed
   ISO9660/SquashFS/overlay/VirtioSCSI built-ins (fixed).
4. **macOS test-toolchain portability bugs** (8 total, all fixed): firmware
   fetcher echoed to stdout polluting `$QCOM_RPM`; bad `local a=$b part=$a.part`
   ordering; firmware RPM resume corruption → full re-download + full-extract
   validation; GNU cpio `-D`/mknod on `/dev` nodes → `--no-preserve-owner` +
   tolerate mknod failures; `find -printf` unsupported → basename loop;
   awk multi-line heredoc "newline in string" → write entries to file, awk
   reads via getline; ESP image extracted root-owned 0444 → mcopy denied →
   `chmod u+rw` after extract; `du -b` → `du -sk *1024`.
5. **arm64 VirtualBox serial syntax** differs from x86: `--uart1 0x3F8` fails
   with "Invalid IRQ". UARTs left disabled; plan was VRDP/EFI framebuffer or
   serial console via a socket (`--uartmode1 server`).
6. **`run-wsl-build.sh` launcher bug**: local `--ref <sha>` path never
   fetches so `FETCH_HEAD` was undefined → `git reset --hard FETCH_HEAD`
   failed. Fixed to reset against `HEAD` (works for fetch and local paths).
7. **AutoYaST experiment abandoned** — temporary HTTP server
   (`~/tw-install`, `python3 -m http.server 8000`) was used to serve a config;
   went with manual GUI install instead; server stopped.
8. **Environment limits on macOS**: Docker daemon not running; UTM CLI blocked
   (OSStatus -1743, needs GUI session); bash 3.2 (no `mapfile`) — script
   avoids it. brew needed `sudo chown -R agentb /opt/homebrew` first.
   GNU cpio is at `/opt/homebrew/opt/cpio/bin/cpio`.
9. **xorriso "SORRY 32"** on isohybrid replay → tolerated (image still
   written; ESP carried as El Torito `/boot/aarch64/efi`).
10. **VM-creation subagent timeout** (600 s) — VM was created anyway; just
    no install. Lesson: long VirtualBox ops need background execution.
11. **Snapshot20260806 hybrid-layout warning** — xorriso reports exit 32
    while extracting usable payloads because the ISO's MBR partition extent is
    beyond its ISO9660 payload. Use `xorriso_sorry_ok` for extraction and
    verification calls; later `cmp`, initramfs-content, GRUB-entry, and
    checksum checks still reject incomplete output.
12. **VM `/tmp` is a 1.9 GB tmpfs** — the expanded module tree exceeds it.
    Run the remaster with `TMPDIR=/home/codex/a16-tmp` (or another disk-backed
    path), not the default `/tmp`.
13. **SoCCP firmware is absent from every Windows source checked** — both the
    local DriverStore and the fully unpacked, SHA-verified ASUS BSP provide
    `RSCP.bin` plus Windows metadata only. They do not provide `soccp.mbn` or
    `soccp_dtb.mbn`; treating `RSCP.bin` as either image is invalid. The next
    source is the device SPI-NOR firmware partition.

## 8. Next steps (exact commands)

```bash
# 1. Boot the verified output ISO on the A16 (Secure Boot OFF) and confirm
#    kernel + DTB bring-up, then check peripherals:
dmesg | grep -i ath12k ; ip link ; ls /lib/firmware/ath12k
dmesg | grep -iE 'i2c|hid' ; cat /proc/bus/input/devices

# 2. If rebuilding in this VM, keep temporary files on /home:
TMPDIR=/home/codex/a16-tmp OUT=/home/codex/a16-output \
  bash scripts/make-opensuse-tumbleweed-usb-iso.sh <bundle> <iso>

# 3. Do not search the ASUS BSP or DriverStore again for SoCCP images. Acquire
#    an authorized dump of the A16 SPI-NOR firmware partition, then locate and
#    validate the genuine signed soccp.mbn and soccp_dtb.mbn. Do not substitute
#    RSCP.bin.

# 4. Before publishing a rebuilt ISO, verify these four checked-in firmware
#    files are in both the rebuilt initramfs and /boot/aarch64/firmware/ payload.
```

WSL side (if building the kernel there instead): `git pull --rebase`, then
`./scripts/run-wsl-build.sh both --ref 3d08ff75a47a3e7e2ab45a3bcab6723b4d906422
--ubuntu-series resolute` (Tumbleweed host: the `opensuse-tumbleweed` mode
skips the kernel build).

## 9. References

- This repo: `jc372/A16Build` (local macOS clone: `~/projects/A16Build`;
  WSL: `/home/jc/A16Build`)
- Branch: `feature/tumbleweed-a16-live-iso`
- Superseded status file: `/Users/agentb/A16Build-tumbleweed-status.md`
- Base ISO: `~/openSUSE-Tumbleweed-DVD-aarch64-Snapshot20260802-Media.iso` (keep untouched)
- VM: `tw-a16` (VirtualBox on macOS coordinator, EFI, 6 GB RAM / 2 CPUs /
  40 GB disk, NAT, SSH forward host:2222→guest:22)
- Experiment scratch (macOS): `~/tw-install/`
- Upstream tracking: patchwork/lore `linux-arm-msm` (glymur/a16 queries)
