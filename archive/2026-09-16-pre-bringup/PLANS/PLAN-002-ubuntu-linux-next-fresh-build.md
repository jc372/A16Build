# PLAN-002 — Fresh linux-next Ubuntu daily build

## Objective

Build a bootable ASUS Zenbook A16 Ubuntu 26.10 ARM64 live ISO from the exact
Ubuntu daily image downloaded on 2026-09-09, using current linux-next master
and avoiding out-of-tree patches unless source inspection proves one is still
required.

## Inputs

- Base ISO: `/mnt/c/Users/cates/Downloads/stonking-desktop-arm64 (2).iso`
  - Resolved 2026-09-15: that filename no longer exists. The same file
    (identical SHA-256) is present as
    `/mnt/c/Users/cates/Downloads/stonking-desktop-arm64_lat.iso`
    (4,236,587,008 bytes). The convenience symlink
    `local-wsl-build/downloads/stonking-desktop-arm64.iso` still points at the
    stale `(2)` name and is dangling — repoint it before rebuilding.
  - Same file is also used as the input by the unrelated
    `/home/jc/A16_Gemini/a16Build.sh` build.
- Base ISO SHA-256: `4b682a946b048b8ea78dcb24bc2e42e036ccef0db280ab9d7aaffce73ec6dd1e`
- Base ISO volume: `Ubuntu 26.10 arm64`, created 2026-09-08
- Kernel: current `linux-next` master fetched at build time
- Config: ARM64 defconfig plus the explicit A16/live-media config fragments

## Approach

1. Clone A16Build cleanly into `/home/jc/A16Build`.
2. Clone a new linux-next tree and inspect current upstream A16 support.
3. Do not run the mailing-list patch series when the board DTS, compatible
   strings, and firmware allowlist are already present.
4. Build from a clean object directory with the defconfig profile.
5. Package the kernel, remaster the exact local ISO, and verify output hashes
   and required ISO payloads.

## Current status

- Clean A16Build checkout created from the maintained feature branch.
- Downloaded ISO identified and hashed; it is intentionally preserved even
  though Canonical's rolling `current` image has since changed.
- Fresh linux-next is commit `1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`
  (`next-20260914`).
- Current source contains the A16 binding, board DTS, DTB Makefile entry,
  PMIC includes, and `asus,zenbook-a16-ux3607oa` in the QSEECOM allowlist.
- The historical three-patch series is fully integrated or superseded.
- Decision: apply zero out-of-tree patches.
- The complete required-config audit passed against current Kconfig.
- Kernel, DTBs, and modules built successfully as
  `7.3.0-rc3-next-20260914`; the kernel tree remained unmodified.
- Kernel bundle packaged as
  `zenbook-a16-7.3.0-rc3-next-20260914.tar.zst`.
- Ubuntu ISO remaster and embedded-payload verification passed. The final ISO
  is `ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media.iso`
  (4,507,566,080 bytes).
- Verified ISO + checksum copied to Windows Downloads
  (`/mnt/c/Users/cates/Downloads/ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media.iso`,
  4,507,566,080 bytes; `sha256sum -c` OK). It has NOT been written to USB yet.
- 2026-09-15 first hardware boot attempt (black screen, no output, reboot) was
  made against a DIFFERENT image — NOT this plan's ISO. See "Boot attempt root
  cause" below.
- 2026-09-15 evening second attempt used THIS plan's ISO (proved from the Rufus
  log and by hashing the copy) and failed the same way. The diagnostic command
  lines could never have shown anything: bare `earlycon` resolves to no console
  on this machine and `CONFIG_FB_EFI` is unset, so no text console exists
  before DRM probes. Full analysis in "Second hardware attempt" below.
- Next: flash
  `ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media-harvest3.iso`
  (Rufus **DD image mode**, Secure Boot off) and let the default entry (ACPI
  diagnostic console) boot. Neither earlier harvest image should be flashed:
  `…-harvest.iso` puts its live-root hook in a phase casper never runs, and
  `…-harvest2.iso` installs the unit but gates it behind `multi-user.target`,
  which on this medium can stay un-reached for minutes — see "The harvest hook
  never ran" below.
  The fixed image self-reports: a ~40-line summary on the panel ~90 s after the
  kernel starts (systemd timer, independent of the multi-user transaction) and
  a tarball of ACPI tables, `/proc/iomem`, device lists, `dmesg` and `lsmod` on
  the first usable FAT sink. Nothing needs typing. Then choose the real path to
  input — see "Third hardware session" below: the two DTB entries **cannot**
  boot as built (no `/memory` node in the DTB), so either install `dtbloader`
  in the internal ESP and use the `firmware/loader-provided DT` entry, or
  hand-build a DTB that adds `/memory` from the harvested memory map.
- 2026-09-16: the maintainer's current install medium is the **stock 26.10
  daily** (`stonking-desktop-arm64_lat.iso`), not a rebuild — it boots this
  machine to a live GNOME session and its installer runs, but the install aborts
  in curtin's in-target apt step because the live clock is weeks behind and apt
  refuses the medium's own signed repository. Fix is a clock set in the live
  session; see "Stock 26.10 daily install attempt" below for the evidence and the
  exact commands (now step 0 of "Next steps").
- 2026-09-16 10:0x: Install retried with the clock fixed — it now fails **later**
  and for a different reason: curthooks' `install-grub` runs `efibootmgr -v` in
  the target chroot and gets `EFI variables are not supported on this system.`
  (exit 2) → `CurtinInstallError`, before GRUB is written to the ESP. Partitions
  17/18 exist on the internal NVMe, the ESP is untouched, no boot entry was
  created. Repair staged at `\A16FIX.SH` on the internal ESP
  (`scripts/a16-finish-boot.sh`); see "Second install attempt" below.
- 2026-09-16 10:2x: That repair was run and worked, but the machine still does not
  boot from the internal disk: GRUB's menu is the installed system's own (single
  kernel `7.2.0-5-generic` + recovery) and every entry ends with
  `you need to load the kernel first`, i.e. the `linux` command did not load a
  kernel and the message comes from the following `initrd`. Evidence and the
  mechanism (which config GRUB actually reads) in "Stage 1 result and the boot
  failure" below; `scripts/a16-stage-esp-boot.sh` (`\A16STAGE2.SH`) is the staged
  next step: it puts kernel + initrd + GRUB modules **on the ESP** and adds a
  diagnostics entry that prints `$prefix`/`$cmdpath` and the module checks.

- 2026-09-16: **The installed system boots.** Operator report: the machine comes up
  from the internal disk, a shell is available, and `apt update && apt upgrade`
  completed. Display is usable; **Wi-Fi (`ath12k`/WCN7850), sound, and the internal
  keyboard + touchpad are still missing**. Network comes from a USB-C dock /
  Ethernet dongle, so nothing here waits on `ath12k`. Which entry got the machine in
  (stage-2 ESP entry vs. the installed system's own menu) is not recorded, and the
  `linux`-does-not-load-the-kernel failure is still unexplained from the host side.
- 2026-09-16: **The agent moves onto the machine.** While the A16 is booted into
  Linux there is no second machine — Windows, WSL and this clone are offline — which
  is why every hardware fact so far had to be reconstructed from photos and harvested
  tarballs. Hermes is installed *on* the A16 and its state imported, so it can read
  `dmesg`, `/sys` and the ACPI tables directly and answer in the same session. See
  "The agent moves onto the A16" below.

## Boot attempt root cause (2026-09-15)

The image on the test USB was not this plan's output. Evidence:

- Rufus 4.14 (running on the A16 itself, Windows 11 ARM64) logged
  `Using image: ubuntu-snapdragon-a16-custom.iso (4 GB)` and wrote it to the
  Samsung flash drive (119.5 GB, FAT32, MBR + Grub2 MBR) in ISO/file mode at
  15:43-15:46. Log: `/mnt/c/Users/cates/Downloads/Rufus/rufus.log`.
- That ISO is the output of a separate, unrelated script:
  `/home/jc/A16_Gemini/a16Build.sh` (a copy also sits at
  `/home/jc/A16_Gemini/ubuntu-snapdragon-a16-custom.iso`; the Downloads copy was
  byte-identical in head/tail and size — `583533c6…` on both sides — and was
  deleted 2026-09-16). It was built 15:36-15:38 today.
- Flashed image SHA-256:
  `583533c6656109446725268b309e1e5e3c3ef3676d4dd47f6c31d36878ae1e57`
  (both copies hash identically). It differs from the base ISO's
  `4b682a94…`, confirming it is a re-mastered image, not the stock one.
- Contents prove it: `/casper/vmlinuz` is
  `Linux version 7.3.0-rc3-g9b87fdc9af2f (jc@Zen) #1 SMP PREEMPT Tue Sep 15
  15:36:31 EDT 2026` (42,609,152 bytes, md5 `cb16e8b3de98b45959ce190120d18762`)
  — torvalds/linux master, `make defconfig`, not this plan's build. The ISO's
  `/boot/grub/grub.cfg` is still the stock 816-byte Ubuntu one (single
  "Try or Install Ubuntu" entry, `quiet splash`, no ACPI/DTB entries), and
  `/casper/initrd` is still the stock 145,997,664-byte Sep 8 initramfs.

Why that image cannot boot the A16 (all documented failures from PLAN-001):

1. `CONFIG_ARM64_VA_BITS_52=y` and `CONFIG_ARM64_PA_BITS_52=y` — the known
   fatal configuration on this SoC.
2. `CONFIG_FB_EFI=y` — must be unset (PLAN-001 section 3).
3. Stock initramfs kept: no custom modules, no A16 DTB, no Qualcomm firmware,
   so casper cannot bring up the live root with a foreign kernel.
4. Stock GRUB entry kept (`quiet splash`, no `console=tty0 earlycon`,
   no `acpi=`, no `module_blacklist=msm`) — early output is suppressed, which
   is why the failure looks like "no output at all, no splash, then reboot".
5. Kernel built from torvalds master instead of the pinned linux-next revision.

The verified A16Build ISO has none of these properties (48-bit VA/PA, no
FB_EFI, 395,565,185-byte rebuilt initramfs carrying the custom modules + DTB +
DSP firmware, four A16 GRUB entries including the MSM-blacklisted diagnostic
console ones).

## Second hardware attempt — correct ISO, still black (2026-09-15 evening)

Reported symptom: DTB entry hangs, the other entry reboots, no output on either.

Verified facts (this attempt did use this plan's ISO):

- Rufus 4.14 on the A16 (`Windows 11 ARM64`) logged
  `Using image: ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media.iso (4.2 GB)`
  (`/mnt/c/Users/cates/Downloads/Rufus/rufus.log`, line 55). The earlier
  "wrong image" cause does not apply this time.
- That ISO is byte-identical to the WSL build output
  (`sha256 947ddd96f06474bccd334bb884ba865e5f60b290a552e04a6513dd153d08dc9c`)
  and contains this build's kernel (`/casper/vmlinuz` =
  `sha256 0db350e9acaa38a98942327a0b91158b58ba2a600f7b7996ba1c13bc9413534a`).
- The flashed ISO's `/boot/grub/grub.cfg` is identical to the known-good
  Aug-13 build's apart from the version string in the menu titles.

Why nothing at all appears on screen (the actual blocker):

- The diagnostic entries pass a **bare `earlycon`**. On this machine that
  resolves to no console: there is no ACPI SPCR/DBG2 table and the Glymur DTB
  has no `/chosen stdout-path`, so no early console is registered.
- `CONFIG_FB_EFI` is unset by design (simpledrm handoff), so the only text
  console is fbcon on a DRM device — simpledrm or the MSM module from the
  initramfs. Before one of those probes, kernel messages go to the dummy
  console, i.e. nowhere.
- Therefore any failure before DRM probing is invisible: a panic at 0.1 s and a
  hang waiting for the panel look exactly the same. `panic=0` on the diagnostic
  entries also means a panic hangs rather than reboots, so "hangs" vs "reboots"
  indicates two different failure classes, not two different kernels.

Console fix (no kernel rebuild needed):

- The kernel is built with `CONFIG_EFI_EARLYCON=y`, and the arm64 EFI stub links
  the kernel's `sysfb_primary_display` symbol directly
  (`drivers/firmware/efi/libstub/primary_display.c` — "makes the EFIFB earlycon
  available very early"). So `earlycon=efifb` prints kernel text onto the
  EFI/GOP framebuffer from the first kernel instructions onward.
- `scripts/make-ubuntu-desktop-usb-iso.sh` gained two additive knobs:
  `DIAGNOSTIC_CONSOLE` (default `earlycon`, unchanged) and `DEFAULT_MENU_ENTRY`
  (default 0, unchanged).

Diagnostic artifacts built (WSL; the Windows Downloads copies of the six
superseded ones listed here were deleted on 2026-09-16 to free space — the WSL
originals under `.diag/out-*` are the masters):

- `ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media-diag-efifb-stockctl.iso`
  4,677,369,856 bytes,
  `sha256 edec6214ad4d9d2fdd79c3298d3bbd0e391fd12fbea16a251deb37362844224d`
  — this plan's current kernel, `earlycon=efifb`, default menu entry 2 (ACPI
  diagnostic console), plus **two stock-kernel control entries** backed by
  `/casper/vmlinuz.stock` and `/casper/initrd.stock` (the base ISO's own kernel
  and initramfs, verified byte-identical to `/casper/vmlinuz` on the base ISO).
  One flash therefore compares custom vs stock kernel on the same medium.
- `ubuntu-desktop-a16-7.2.0-rc7-next-20260810-g3d08ff75a47a-va48-resolute-modular-drm-live-media-diag-efifb.iso`
  4,420,993,024 bytes,
  `sha256 9cc79ee46321da85220a80d49ecdab2cde88914e852d25c6f89ed5a90adf6417`
  — the pinned known-good kernel bundle plus the exact Aug-14 resolute base ISO
  from `A16Build.sav`, same script and entries plus `earlycon=efifb`. This is
  the rebuild of the configuration that last reached a GUI.
- Superseded: an earlier `…-stonking-…-diag-efifb.iso` (4,507,566,080 bytes,
  `sha256 0d5494d3…`) — same as the stockctl image but without the control
  entries. Do not flash it; the stockctl image replaces it.

Both current images were verified after writing: `sha256sum -c` OK,
`set default=2`, `earlycon=efifb` on both diagnostic entries,
`module_blacklist=msm` present, six `linux /casper/vmlinuz*` lines in the
stockctl image (four custom + two stock) and the stock payloads match the base
ISO byte for byte.

New script knobs (all additive, defaults preserve the previous behaviour):
`DIAGNOSTIC_CONSOLE` (`earlycon`), `DEFAULT_MENU_ENTRY` (`0`), `STOCK_ENTRIES`
(`0`, set `1` to carry the stock kernel/initramfs and the two control entries).

Test order for the next hardware session (Secure Boot off, Rufus **DD image
mode**):

1. `…-diag-efifb-stockctl.iso` → let the default (ACPI diagnostic) entry boot
   and photograph whatever text appears; `earlycon=efifb` should print kernel
   messages on the panel from the first instructions.
2. If it is silent, boot the `stock Ubuntu kernel diagnostic console (control)`
   entry on the same stick. Text there but not on the custom entries ⇒ the
   medium, GRUB handoff and `earlycon=efifb` all work and the custom kernel is
   the fault. Silence there too ⇒ nothing below the custom kernel is being
   reached at all: look at the flash path, firmware state and the GRUB handoff
   rather than at A16Build kernel options.
3. Then the DTB diagnostic entry, and finally
   `…-resolute-…-diag-efifb.iso` (pinned known-good kernel bundle) to place the
   regression between `next-20260810` and `next-20260914` if the stock kernel
   boots and the current one does not.

Supporting evidence gathered offline:

- Kernel config diff old vs new build: 140 lines, no addressing/display
  regressions (`VA_BITS_48`/`PA_BITS_48` hold, `FB_EFI` still unset,
  `SIMPLEDRM`/`SYSFB`/`MSM=m` unchanged). New-in-next: `CONFIG_DMABUF_DEBUG=y`,
  `CONFIG_PREEMPT_DYNAMIC=y`, `CONFIG_COMMAND_LINE_SIZE=2048`.
- Glymur board DTB grew 157,116 → 161,943 bytes with 693 property changes,
  overwhelmingly phandle renumbering, but real additions exist: a new
  `pcie@1c10000` controller (status "disabled") with its OPP table, the
  `qcom,glymur-qmp-gen5x8-pcie-phy` (`phy@f00000`, status "disabled") and extra
  interconnect/user-OPP properties on the USB nodes.
- Both bundles pass `config-audit.txt` (all 111 required options).
- `stonking-desktop-arm64_lat.iso` re-hashed and matches the plan's recorded
  `4b682a94…` (and is the file the new ISO was rebuilt from).
- The Aug-14 "resolute" ISO in Windows Downloads does **not** match the
  recorded `.sha256` (`fbfd9a47…` vs recorded `75ed8c72…`); the Downloads copy
  was never verified, so the rebuilt `-diag-efifb` resolute image supersedes it
  as the known-good reference. That unverified copy (hash `fbfd9a47…`) was deleted
  on 2026-09-16; the `-diag-efifb` rebuild is retained in Downloads.
- The WSL `linux-next` clone is shallow (`--depth 1`), so any date-bisect needs
  extra fetches (`next-2026MMDD` tags).
- **`/mnt/c` copies are not trustworthy on their own.** The first copy of the
  resolute diagnostic image differed from its source in exactly 4 bytes at
  offset ~523 MB with an identical file size; re-copying and running
  `sha256sum -c` from the Downloads directory verified. Always hash the file in
  place on the Windows side before telling anyone to flash it.

## Fresh start — kernel configured like the kernel that boots (2026-09-15, late)

Direction change, per maintainer request: stop inheriting this repo's
assumptions (arm64 defconfig + `config/a16-required.config` fragments plus the
"52-bit is fatal", "FB_EFI must be off", "ACPI is the working path" folklore)
and instead start from a kernel configuration that demonstrably boots the
machine.

Source of truth for that configuration:

- The base ISO's live kernel is `linux-image-7.0.0-14-generic` (7.0.0-14.14).
- Its config was recovered twice, independently, and the two copies are
  byte-identical (`sha256 71c16348b6d60ce2d255836de36d20dbb64e54fdf6617d09489d9b7c0aa313e9`):
  - `/casper/minimal.squashfs` → `/boot/config-7.0.0-14-generic` (the live root
    actually mounted at boot), and
  - `linux-headers-7.0.0-14-generic_7.0.0-14.14_arm64.deb`
    (`/usr/src/linux-headers-7.0.0-14-generic/.config`) from
    `ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/`.
- Checked in as `config/ubuntu-generic-arm64.config`.

What that config says (independently confirming the old assumptions, i.e. they
were right but redundant): `ARM64_VA_BITS_48`/`PA_BITS_48`, 4K pages,
`# CONFIG_FB_EFI is not set`, `SYSFB`/`SYSFB_SIMPLEFB`/`SIMPLEDRM`/
`FRAMEBUFFER_CONSOLE` built in, `DRM_MSM=m`, `DRM_PANEL_EDP=m`,
`BLK_DEV_SR=y`, `EFI_EARLYCON=y`, `EFI_VARS_PSTORE=m`. The old
`config/a16-required.config` audit passes 100% against it. Differences worth
noting: `ARM64_ACPI_PARKING_PROTOCOL=y` (ours had it off), `EFI_ZBOOT=y`
(Ubuntu ships a compressed EFI zboot kernel), `MODULE_SIG=y`,
`MODULE_COMPRESS_ZSTD=y`, `ISO9660_FS=m`/`UDF_FS=m`/`OVERLAY_FS=m`/
`I2C_HID_ACPI=m` (modules rather than built-ins).

Changes made for it:

- `scripts/build.sh`: new `ubuntu`/`distro` profile that copies that config and
  runs `olddefconfig`, forcing nothing except disabling module signing and BTF,
  clearing `SYSTEM_TRUSTED_KEYS` (Ubuntu's config points at
  `debian/canonical-certs.pem`, which only exists in Ubuntu's own tree and broke
  the build outright), and refusing to proceed if any key/hash option still
  references a `debian/` path.
- `scripts/make-ubuntu-desktop-usb-iso.sh`: the bundle-config check now verifies
  *presence* (`=y` or `=m`) instead of demanding built-ins, because the rebuilt
  initramfs carries the full module tree; requirements stated as `=m` stay
  exact.

Copy-integrity fix (important, cost two bad flashes' worth of confusion):

- Writing large ISOs into `/mnt/c` from WSL silently corrupted them: the
  resolute image arrived with 4 wrong bytes at an identical size, and the
  stockctl image arrived with a completely different SHA-256 at an identical
  size, both confirmed with Windows' own `Get-FileHash` (so not a read
  artifact).
- Working method: copy with `robocopy /J` reading
  `\\wsl.localhost\Ubuntu\…` and always verify with `Get-FileHash` on the
  Windows side. Scripts live at
  `/mnt/c/Users/cates/Downloads/a16-copy-verify.ps1` and `a16-verify.ps1`.
- Re-copied and verified: both diagnostic ISOs are now correct on the Windows
  side (`…stonking-…-diag-efifb-stockctl.iso` = `edec6214…`,
  `…resolute-…-diag-efifb.iso` = `9cc79ee4…`).

### Fresh-config kernel and image (built 2026-09-15, late)

- `KERNEL_CONFIG_PROFILE=ubuntu OUT=local-wsl-build/kernel-out-ubuntu
  ./scripts/build.sh local-wsl-build/linux-next` then
  `DEST=.diag/out-ubuntu ./scripts/package.sh …` — linux-next
  `1a1de54f` (7.3.0-rc3-next-20260914) built against the Ubuntu config as-is.
  Image 73,304,576 bytes; 8,494 modules; `config-audit.txt` still reports every
  `a16-required.config` line OK.
- First build attempt failed on Ubuntu's cert path
  (`No rule to make target 'debian/canonical-certs.pem'`); the profile now
  clears the key/hash strings and fails fast if any are left pointing at
  `debian/`.
- Ubuntu's config also builds with full debug info: the module tree came out at
  9.5 GB, which would have produced an unusable initramfs. Fixed two ways —
  the profile now disables `DEBUG_INFO*`/`BTF`, and `package.sh` installs
  modules with `INSTALL_MOD_STRIP=1`. The already-built tree was stripped by
  hand (9.5 GB → 680 MB).
- Image built from that bundle:
  `ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media-ubuntucfg.iso`,
  4,787,929,088 bytes,
  `sha256 39d7c7a4372b7912555f422070bdb7067130af78bcbf2ef33bc5b60042ea679a`
  (custom initramfs 479,316,350 bytes). Verified in the ISO: kernel == bundle
  Image, six `linux /casper/vmlinuz*` entries, `set default=2`, `earlycon=efifb`
  on both diagnostic entries, stock-kernel control entries present.

## Emulation smoke boot (2026-09-15, late)

`sudo` needs a password (not available to the agent), so QEMU 10.2.1 and AAVMF
2025.11 were downloaded as debs and unpacked rootlessly into
`~/qemu-rootless/root`. Helper scripts: `.diag/qemu-smoke-{A,B,C,D}.sh`,
`.diag/qemu-shot.py`. No `/dev/kvm` in this WSL2 guest, so everything runs
under TCG.

**Run A (successful) — kernel + initramfs + casper, fresh-config image.**
Direct boot of the ubuntucfg image's `/casper/vmlinuz` + `/casper/initrd` with
the ISO attached, `console=ttyAMA0 earlycon=pl011,0x9000000`. It reached
systemd on the ISO's own squashfs root and was starting the desktop bootstrap
about 145 s in:

- `earlycon: pl11 MMIO:0x00000009000000` / `printk: legacy bootconsole [pl11] enabled`
- `Begin: Running /scripts/casper-premount ... done.`
- `overlayfs: null uuid in non-single lower fs '/', falling back to xino=off,index=off,nfs_export=off.`
- `Begin: Running /scripts/casper-bottom ... done.`
- systemd bringing up units, apparmor profiles loading,
  `snap-update-ns.ubuntu-desktop-bootstrap`

So the kernel, the rebuilt initramfs, the module tree, casper's live-media
detection and the squashfs layers all work with the Ubuntu-config kernel.

Two things that run surfaced:

- `rtc_pl031: module verification failed: signature and/or required key missing
  - tainting kernel` — that image still had `MODULE_SIG=y` (the profile disables
  signing only after this build). Cosmetic: `MODULE_SIG_FORCE` is off, so the
  module loads.
- `systemd[1]: Failed to find module 'autofs4'` even though
  `fs/autofs/autofs4.ko` ships (`CONFIG_AUTOFS_FS=m` in both configs) and
  `/lib/modules/7.3.0-rc3-next-20260914/` is the running release. Not
  boot-blocking — other modprobes in the same session succeed — but unexplained.

**Runs B–F (inconclusive) — firmware/GRUB/panel path.** AAVMF never hands the
kernel a usable GOP here, with every display configuration tried:

- `-display none` + virtio-gpu → panel shows `Display output is not active.`
- VNC-backed virtio-gpu → same message.
- WSLg SDL display (`-display sdl`, after pulling `qemu-system-gui` and
  `libpulse0` into the rootless prefix) + virtio-gpu → same message.
- `-device ramfb` → panel shows QEMU's own `Guest has not initialized the
  display (yet).`

Tooling gotchas from these runs, for whoever tries next: the SDL UI module
needs `libpulse0` present in the search path or QEMU dies with SIGSEGV
(exit 139, `failed to open module: libpulsecommon-17.0.so`) rather than a clean
error; and attaching a serial console to a non-tty emits
`tcsetattr: Inappropriate ioctl for device` noise from SDL.

Serial stops at the firmware banner in all of them, so the firmware is not even
reaching the ISO's GRUB. Practical detail learned here: UEFI can only boot the
ISO from a real CD-ROM (`-device scsi-cd` behind `virtio-scsi-pci`); an ISO
attached as virtio-blk is a bare ISO9660 filesystem with no ESP and is not
bootable by firmware at all.

Consequence: this environment cannot exercise the ISO's own GRUB entries or the
`earlycon=efifb` panel console. That claim stays unverified until the A16 boots
an efifb-enabled entry — its firmware does have an active GOP (the GRUB menu
renders on the panel), which is what `earlycon=efifb` needs.

## Third hardware session (2026-09-15, late): ACPI entries boot, no input

Maintainer report: on `…-ubuntucfg.iso` (the only image tried this session) the
two DTB entries do not boot at all, the two ACPI entries do, the **graphics**
variant boots much faster than the diagnostic one, and there is still no
internal keyboard or touchpad. Progress is real: the ACPI entries now boot on
this kernel/config combination, and the `earlycon=efifb` console work has
nothing left to prove.

The rest of this section is offline analysis of *why* input is missing and why
the DTB entries cannot boot as built. No new hardware run was needed for it.

### 1. ACPI mode cannot give keyboard/touchpad (firmware IDs are unmatched)

The A16's own Windows installation was interrogated read-only from WSL
(`Get-PnpDevice`, dump kept at
`/mnt/c/Users/cates/Downloads/a16-acpi/acpi-devices.csv`). What the firmware
describes:

- I2C controllers: `ACPI\QCOM0F10` (six instances), "Qualcomm(R) I2C Bus Device"
- GPIO controller: `ACPI\QCOM0F0C`, "Qualcomm(R) System Manager GPIO Device"
- I2C-HID children, all class `HIDClass` / "I2C HID Device":
  `ACPI\ASUP1207\3`, `ACPI\QTEC0001\3`, `ACPI\QTEC0003\3`,
  `ACPI\VEN_MSFT&DEV_0001&SUBSYS_CRD08480&REV_0001`

linux-next matches none of them:

- `drivers/i2c/busses/i2c-qcom-geni.c:1302` — ACPI table is
  `{ "QCOM0220", "QCOM0411" }` only.
- No file under `drivers/` mentions `QCOM0F0C`; `pinctrl-msm`/`pinctrl-glymur`
  have no ACPI match table, so the TLMM GPIO controller (and therefore every
  `GpioInt` interrupt behind the HID devices) never comes up under ACPI.

Consequence: in ACPI mode no I2C adapter is ever registered, so the HID
children are never enumerated — the missing keyboard/touchpad is not a config
or module-loading problem. `i2c_hid_acpi.ko`, `i2c_hid.ko`,
`hid_multitouch.ko`, `i2c_qcom_geni.ko` and `pinctrl_glymur.ko` are all present
in the bundle's module tree and initramfs. Making ACPI-mode input work means
porting geni-I2C and the TLMM GPIO block to ACPI (clocks, interconnect, DMA,
pinctrl and GpioInt translation) — a driver project, not a build knob.

### 2. Device tree is the only route to input — and its fix is known

Qualcomm's own enablement series states the capability plainly: in
`[PATCH 0/3] X2EE ASUS Zenbook A16 (UX3607OA) support` (Konrad Dybcio,
2026-07-21) the "currently working" list includes **keyboard, touchpad, lid
switch**, alongside display, GPU, Wi-Fi and audio. That list describes the DT
path, and it matches the DTS nodes already in our tree
(`arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a16-ux3607oa.dts`):
`keyboard@15` on i2c19 (ASUSTek 0B05:4B42), `touchpad@15` on i2c0, `hid@17` on
i2c10, `touchscreen@10` on i2c8, with the EC at 0x76 on i2c9.

### 3. Root cause of "the DTB does not boot at all"

**The shipped DTB has no `/memory` node, and glymur.dtsi has none either.**
Verified three ways:

- `grep -c 'memory@' glymur.dtsi` → 0, and no `glymur*` board file adds one.
- `fdtdump` of the shipped 161,943-byte
  `glymur-asus-zenbook-a16-ux3607oa.dtb` (and of `glymur-crd.dtb`) shows no
  `device_type = "memory"` anywhere.
- Contrast: 36 other Qualcomm SoC dtsi files, including `hamoa.dtsi` (the X1E
  SoC used by the Zenbook A14, T14s, XPS 13 9345 …), carry the skeleton
  ```dts
  memory@80000000 {
          device_type = "memory";
          /* We expect the bootloader to fill in the size */
          reg = <0 0x80000000 0 0>;
  };
  ```
  i.e. on X1E the node exists with a zero size for the bootloader to fill,
  while on Glymur the node is absent entirely — nothing to fill. That is a real
  difference between the platforms, not a build problem.

On arm64 the DT boot path registers RAM only from `/memory` nodes
(`early_init_dt_scan_memory()`, `drivers/of/fdt.c`), and the device tree is only
unflattened when ACPI is off (`arch/arm64/kernel/setup.c:341`). Qualcomm
platforms hand the OS a device tree that already describes memory — the
firmware's own tree installed in the UEFI configuration table, with the
Linux/OS tree applied on top (`dtbloader`, github.com/TravMurav/dtbloader,
which the A16 is already listed for as `qcom\glymur-asus-zenbook-a16-ux3607oa.dtb`).

GRUB's `devicetree` command *replaces* whatever is in that table with our file.
The kernel then has no RAM: it dies before any console device exists, so not
even `earlycon=efifb` can print a panic. That is precisely the reported symptom,
and it also explains the historical "white dot → black screen" DT failures.
No menu-entry or cmdline change can fix this: **the two DTB entries as built
cannot boot.**

Two workable routes, in preference order:

1. Hand-build a DTB that adds `/memory` (and keeps the reserved regions) from
   the real memory map, so GRUB's `devicetree` works again. The ISO builder now
   takes `DTB_OVERRIDE=<file>` for exactly this, so no kernel rebuild is needed
   — `dtc`/`fdtdump` are available on the build host. Two variants worth testing
   in one image: the upstream-style zero-sized placeholder (in case the loader
   fills it) and the node with the real size baked in. Needs the true
   usable-RAM/reserved layout, which the harvest captures (`/proc/iomem`,
   `/sys/firmware/memmap`, EFI systab).
2. Install `dtbloader` into the internal ESP (Secure Boot is already off) so the
   firmware/loader path offers a tree with memory, then boot `acpi=off` with
   **no** `devicetree` line (that entry already exists in harvest builds). The
   A16 is already in dtbloader's device database, so this needs no upstreaming;
   it does need the driver built and placed on the internal ESP, which a live
   session could do unattended once the harvest shows the ESP is reachable.

Also queued for the DT path: the pending
`[PATCH] HID: asus: support the Zenbook A16 (UX3607OA) keyboard` (2026-07-24)
adds the `0B05:4B42` I2C keyboard quirk plus the Fn/media usage mappings
(0x85 → KEY_CAMERA, 0x86 → KEY_PROG1, 0x5f → KEY_PROG2) and a
camera-companion filter quirk. Typing should work without it; the special keys
will not. Worth applying out-of-tree once the DT path boots.

### 4. Harvest build: the machine now reports its own state

One flash cycle should answer everything a keyboard would have. Additive knob
`A16_HARVEST=1` in `scripts/make-ubuntu-desktop-usb-iso.sh`:

- ships `scripts/a16-harvest.sh` inside the initramfs; the existing
  `scripts/local-bottom/a16-live-root` hook installs it plus a oneshot
  `a16-harvest.service` into the live root (the same mechanism that already
  copies the custom modules and firmware into Casper's overlay);
- on every custom entry, 25 s after the target is reached, the collector
  gathers DMI identity, `/proc/cmdline`, `/proc/iomem`, `/sys/firmware/memmap`,
  `/sys/firmware/fdt` if present, `/sys/firmware/efi/systab`, the raw ACPI
  tables, input devices, i2c/hid/gpio/acpi device lists, modules, interrupts,
  block layout, `dmesg`, `lsmod` and `blkid`;
- prints a compact summary (~40 lines, sized for a photograph) to the panel
  console, then writes a tarball of everything to the first usable FAT/ext4
  sink — a volume labelled `A16LOG`, else the internal ESP (ample space, spread
  over `EFI/Microsoft`), else the live medium's own 6 MB ESP (only ~1 MB free,
  so it degrades to `summary.txt` + `dmesg.txt.gz` when the tarball will not
  fit). Every attempted sink and the free space it saw is reported on the
  console;
- adds a fifth custom entry, `firmware/loader-provided DT diagnostic console`
  (`acpi=off`, no `devicetree` line, `earlycon=efifb`), i.e. the entry that
  becomes meaningful the moment dtbloader is installed;
- `VARIANT_SUFFIX` knob so these images can be told apart by filename
  (`…-live-media-harvest.iso`), because wrong-image flashes have burned this
  project twice already.

Artifact: `ubuntu-desktop-a16-7.3.0-rc3-next-20260914-va48-stonking-modular-drm-live-media-harvest.iso`,
4,787,929,088 bytes,
`sha256 500af9424b9640027fb7258cb36366aff2d14c79a45e892054b662a72cdfe64b`
(built from the existing `zenbook-a16-7.3.0-rc3-next-20260914.tar.zst` bundle and
the verified `stonking-desktop-arm64_lat.iso`; default menu entry 2 = ACPI
diagnostic console, so the summary is visible without touching anything).
Built twice: the second build carries the fixed collector inside the initramfs
and `DTB_OVERRIDE=.diag/dtbtest/a16-placeholder.dtb`, i.e. the DT entries now
ship a tree that has the upstream X1E-style
`memory@80000000 { device_type = "memory"; reg = <0 0x80000000 0 0>; }`
placeholder in front of `reserved-memory`. If the firmware/loader fills that
size in, DT boot comes alive with no further work; if not, nothing is lost
relative to the unpatched tree.

Verified in the final artifact (`xorriso` extraction, not the builder's own
checks): `sha256sum -c` OK; 9 menu entries with 7 `linux /casper/vmlinuz*` lines
and 2 `devicetree` lines; `set default=2`; the new
`firmware/loader-provided DT diagnostic console` entry exists with `acpi=off`
and no `devicetree` line; the `/casper/dtbs/.../glymur-asus-zenbook-a16-ux3607oa.dtb`
inside the ISO is the overridden 162,015-byte tree carrying `memory@80000000`;
the initramfs carries the collector (`usr/local/sbin/a16-harvest`, fix included).
The superseded first build of the same name (no DTB override, older collector)
and the earlier `…-stockctl.iso` / `…-diag-efifb.iso` must not be flashed.
Copy to Windows with `a16-copy-harvest.ps1` (robocopy `/J` + `Get-FileHash`),
never with a direct write into `/mnt/c`.

## Next steps (exact commands)

- **Wi-Fi is DONE (2026-09-16).** The A16's QCC2072 (`17cb:1112`, SUBSYS `E14F105B`) needed a
  board-data entry for *this* machine's key, built from its own Windows package and rebuilt
  with QCA's bdencoder: `firmware/ath12k-board-2-qcc2072-e14f/` (file + pristine distro
  container + README) and `scripts/make-a16-qcc2072-board-2.sh` (reproduces
  `314e2d57…`; `--install` puts it back after a linux-firmware upgrade). Verified on
  hardware: zero `failed to fetch board data` lines, `wlP4p1s0` up, 50+ APs, 29 Mbit/s.
  Details and the full lesson list: `notes/2026-09-16-hermes-wifi-board-data.md`.
  Two follow-ups, **not** board-data: the profile associates to the AP's weakest 6 GHz BSSID
  (`22:36:26:d8:29:23`, −77 dBm, 17 Mbit/s TX) while its 5 GHz/2.4 GHz BSSIDs report 100% —
  try `nmcli con modify hn 802-11-wireless.band a` + `wifi.powersave 2`; and while the
  Ethernet dongle is connected it holds the default route, so Wi-Fi carries nothing (unplug
  and re-test).
- **Sound: measured, and it is upstream work — see
  `notes/2026-09-16-hermes-audio-state.md`.** Card + all four WSA884x amps come up, every
  provider is bound (no deferred probes), the CRD graph is already single-playback-path, and
  the stream reaches RUNNING while the DSP consumes nothing. Cross-SoC topologies
  (Romulus / Dell-XPS-13-9345 / Lenovo-Yoga-Slim7x) are all rejected identically
  (`Failed to start APM port 105`, `ASoC error (-22)`), so topology-swapping is exhausted.
  The second amp bus (`6ca0000.soundwire`) reports `SWR bus clsh detected` at boot and its
  amps end in Alert; pins and reset lines are described correctly (ruled out). Windows
  firmware has no Linux topology (no `CoSA` magic anywhere), only `acdb_cal.acdb`. Fix paths:
  build this machine's topology around that ACDB with Audioreach tooling, or pick up an
  upstream `GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin` when it exists. Interim: mute the
  sink so video plays.

```bash
cd /home/jc/A16Build

# 0. MOVE THE WORK ONTO THE A16 (done 2026-09-16). The installed system boots and now
#    runs Hermes on the machine itself, so the photo/ESP-tarball round trip is over.
#    Payload contents and install/import commands: "The agent moves onto the A16"
#    above. First commands in the installed session:
#      sudo bash /media/$USER/<STICK>/a16-triage.sh   -> tarball lands back on the stick
#      ls /sys/firmware/efi/efivars/ ; sudo apt install efibootmgr && sudo efibootmgr -v
#      dmesg | grep -iE 'ath12k|QCOM0F1|QCOM0F0C|i2c-qcom-geni|hid' ; ip -br link; rfkill list
#    Still open from step 0a: WHICH entry boots the installed system (stage-2 ESP entry
#    or the system's own menu). Record it next time the machine is up.

# 0a. FINISH THE INSTALL'S BOOT (2026-09-16, do this before anything else).
#     Stage 1 ran: scripts/a16-finish-boot.sh (staged as \A16FIX.SH) did its job —
#     grub-install exited 0 in both layouts and update-grub wrote the target's
#     /boot/grub/grub.cfg (see A16BOOT.LOG, now in harvest/2026-09-16-esp/). The
#     ESP therefore carries the target's signed shim/GRUB and the stub
#     \EFI\ubuntu\grub.cfg, and the panel menu is the installed system's own menu
#     (one kernel installed: 7.2.0-5-generic, plus recovery).  But EVERY entry
#     dies: GRUB will not load the kernel, and the line the operator sees comes
#     from the command after it (initrd):
#        "you need to load the kernel first"
#     Stage 2 removes the question from the path and collects the evidence:
#     scripts/a16-stage-esp-boot.sh, staged on the ESP as \A16STAGE2.SH
#     (14,173 B, sha256 94f55653...). Boot the stock 26.10 daily, open a terminal,
#     and run:
#       sudo mount /dev/nvme0n1p12 /mnt
#       sudo bash /mnt/A16STAGE2.SH
#     It writes, all on the ESP and all readable from Windows afterwards:
#       A16DIAG2.TXT   kernel file format/bytes, /boot listing, module presence
#                      (gzio/ext2/linux/...), ext4 features, fstab, /etc/default/grub
#       P17-GRUB.CFG   the installed system's generated /boot/grub/grub.cfg
#       A16STAGE2.LOG  the run's own log
#       A16ESP-BACKUP/ the three configs that were in place before the run
#     and stages a boot that needs nothing but the ESP: kernel + initrd + the
#     target's arm64-efi module directory copied to \a16boot\, with a four-entry
#     menu written to EVERY location a GRUB on this ESP reads a config from
#     (\EFI\ubuntu\grub.cfg — the embedded prefix both firmware Linux entries use,
#     \EFI\ubuntu_snapdragon\grub.cfg, \EFI\BOOT\grub.cfg, \boot\grub\grub.cfg):
#       0 installed Ubuntu, kernel+initrd from the ESP   (no ext4 involved)
#       1 installed Ubuntu, its own generated grub.cfg   (normal path kept working)
#       2 diagnostics: prefix, cmdpath, staged payload, module checks (sleeps 90 s)
#       3 Windows Boot Manager
#     Then reboot, firmware boot menu (F2/F12), pick the Linux entry, and choose
#     entry 0; if it fails, pick the diagnostics entry and photograph the panel.
#     Re-copy the script to the ESP after any edit to it:
#       powershell -File C:\Users\cates\Downloads\a16-esp-stage2.ps1   (elevated, UAC)

# 0. Install path: the stock daily boots and installs on this machine; the clock
#    is no longer the blocker (fixed 2026-09-16 by hand in the live session; the
#    remaster-side clock bootstrap is still not implemented). If the installer is
#    ever re-run, set the clock first as below, and expect the SAME install-grub
#    failure at the end — the machine gives Linux no EFI variables to write.
#      sudo timedatectl set-ntp false
#      sudo date -s '2026-09-16 10:30:00'      # today's real date; NOT past
#      date                                    # the medium's Valid-Until
#      ubuntu-desktop-bootstrap                # relaunch, then Install
#    (2026-09-22 is the bundled repo's expiry, so a clock beyond that fails for
#    the opposite reason. Connecting a network and letting NTP sync also works.)
#    Remaster-side class fix, not implemented yet: write the build epoch into the
#    ISO root and have the existing casper-bottom hook install a oneshot unit that
#    sets the clock from it when the session clock is behind — then no A16 media
#    depends on this machine's missing RTC any more.

# 1. Build the harvest image (DTB entries carry the upstream-style zero-sized
#    memory placeholder: harmless if nothing fills it, decisive if something
#    does). ~15 min, no kernel rebuild. VARIANT_SUFFIX distinguishes this from
#    the harvest-dead first image and the harvest2 trigger bug, neither of which
#    must be flashed again.
A16_HARVEST=1 STOCK_ENTRIES=1 DEFAULT_MENU_ENTRY=2 DIAGNOSTIC_CONSOLE=earlycon=efifb \
VARIANT_SUFFIX=-harvest3 DTB_OVERRIDE=$PWD/.diag/dtbtest/a16-placeholder.dtb \
DOWNLOAD_DIR=$PWD/local-wsl-build/downloads TMPDIR=$PWD/.diag/tmp-harvest3 OUT=$PWD/.diag/out-harvest3 \
  bash scripts/make-ubuntu-desktop-usb-iso.sh \
    .diag/out-ubuntu/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst \
    local-wsl-build/downloads/stonking-desktop-arm64.iso

# 1b. Confirm the hook is where casper will run it, before flashing:
#       xorriso -indev <iso> -osirrox on -extract /casper/initrd /tmp/i \
#         && gzip -dc /tmp/i | cpio -i --to-stdout scripts/casper-bottom/ORDER \
#         | grep 65a16-live-root
#       ... and that the hook installs a *timer* (OnBootSec), not a unit gated
#       on multi-user.target.

# 2. Copy it to Windows with the harness (robocopy /J + Get-FileHash), never a
#    direct write into /mnt/c, then flash (Rufus, DD image mode, Secure Boot
#    off). Boot the default ACPI diagnostic entry and WAIT: the timer fires 90 s
#    after the kernel starts, so the summary is on the panel at roughly 90-120 s,
#    i.e. while the boot log is still scrolling. Photograph the summary; the
#    tarball lands on the first usable FAT sink (internal ESP). Retrieve it from
#    Windows with:
#      powershell -File C:\Users\cates\Downloads\a16-read-log.ps1

# 3. The harvest is in hand (2026-09-16): bake its ranges into the DT and let the
#    DTB entries boot it — no kernel rebuild. Use the NET list committed at
#    harvest/2026-09-16/system-ram-ranges-net.txt (35 ranges, 26.57 GiB): raw
#    System RAM minus the firmware carveouts inside it, which are secure-world
#    memory the kernel must not touch.
BASE=.diag/out-ubuntu/zenbook-a16-7.3.0-rc3-next-20260914/dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb
RANGES=$(grep -v '^#' harvest/2026-09-16/system-ram-ranges-net.txt | head -1)
scripts/make-a16-dtb-memory.sh "$BASE" .diag/dtbtest/a16-memory-acpi.dtb ranges "$RANGES"

# 4. Build the DT-path experiment: the memory-patched DTB, harvest still enabled,
#    and the default entry moved to the DTB diagnostic console (index 0) — the
#    A16 has no keyboard to pick entries with, so the default is the only entry
#    that can run unattended.
A16_HARVEST=1 STOCK_ENTRIES=1 DEFAULT_MENU_ENTRY=0 DIAGNOSTIC_CONSOLE=earlycon=efifb \
VARIANT_SUFFIX=-dtmem DTB_OVERRIDE=$PWD/.diag/dtbtest/a16-memory-acpi.dtb \
DOWNLOAD_DIR=$PWD/local-wsl-build/downloads TMPDIR=$PWD/.diag/tmp-harvest4 OUT=$PWD/.diag/out-harvest4 \
  bash scripts/make-ubuntu-desktop-usb-iso.sh \
    .diag/out-ubuntu/zenbook-a16-7.3.0-rc3-next-20260914.tar.zst \
    local-wsl-build/downloads/stonking-desktop-arm64.iso

# 5. Flash and boot. If the DT path now has RAM it should reach a console and the
#    timer self-reports (tarball on the internal ESP); with luck the I2C-HID
#    keyboard/touchpad enumerate too, which ACPI mode cannot do. No output and an
#    empty ESP means the DT path still dies before any console exists.
#    Experiment worth trying next: the firmware holds exactly 16 GiB back at
#    0x8800000000-0x8bffffffff (544-600 GiB, marked reserved). Adding
#    0x8800000000:400000000 as one more memory@ node asks for the full 48 GiB —
#    but it is firmware-reserved memory, so treat it as a probe, not a fix.
```

The `System RAM` lines of the harvested `/proc/iomem` are the authority for the
`ranges` argument: they are exactly the ranges the kernel was happy to use in
ACPI mode, so re-declaring them keeps the secure-world carveouts out of the
kernel's hands. GRUB's `cutmem 0x8800000000 0x8fffffffff` workaround (copied from
Canonical's Snapdragon GRUB config, active whenever SMBIOS reports Snapdragon and
`lockdown != y`; emitted by `scripts/make-ubuntu-desktop-usb-iso.sh`) does **not**
affect those lines: the cut window is 32 GiB at 544-576 GiB, entirely above this
machine's RAM, whose top is 48 GiB (`0x0c00000000`; SMBIOS Bank 0 =
51,539,607,552 B, Windows `TotalPhysicalMemory` = 51,127,103,488 B = 47.6 GiB).
The harvested map is complete, and the 48 GiB sanity check is now *explained*
rather than a discrepancy: 31.604 GiB of `System RAM` + exactly 16.00 GiB marked
`reserved` at `0x8800000000-0x8bffffffff` = 47.60 GiB, matching Windows'
`TotalPhysicalMemory` (51,127,103,488 B = 47.62 GiB). The `cutmem` window sits
inside that reserved region, so it only ever removed memory this boot mode does
not get anyway.


## The harvest hook never ran (2026-09-16)

The harvest image booted on hardware and reported nothing: no summary block and
no tarball on any sink. Confirmed from the machine itself, not from the panel:

- Two boots happened in the Windows-off window 06:46:01–06:55:03 (`Kernel-General`
  12/13). Photos of the panel show the first at ~49 s uptime in late
  `initcall` traces and the second reaching `Reached target multi-user.target`
  (≈169 s), `Finished cloud-final.service`, and
  `Finished casper-md5check.service` (≈190 s) with `vga_arb_device_init` /
  `acpi_mpam_parse` in the log — i.e. **the ACPI diagnostic console entry boots
  and works**, as designed.
- The internal ESP (disk 0 partition 12, label `SYSTEM`, 467 MB) has no `a16-*`
  file and nothing written during that window; the live medium's own root has
  none either (`a16-read-log.ps1` finds nothing).

Root cause is in the ISO builder, not the kernel or the collector: the
live-root hook was written to `scripts/local-bottom/a16-live-root`, but **no
casper boot ever runs that phase**. `/init` executes `mount_top`,
`mount_premount` and `mountroot`; casper overrides `mountroot()` and
`local_bottom()` is only called from `local_mount_root()`. Consequences: the
custom module tree/firmware were never copied into the live root *and* the
`a16-harvest.service` unit was never installed, so the collector never existed
in the running system. Instrumented against the media's own `/casper/initrd`:

- `scripts/functions:128 run_scripts() { initdir=${1}; shift; . "${initdir}/ORDER"; }`
  — a phase runs **only** what its `ORDER` file sources, so dropping a script
  into a phase directory is dead weight on its own.
- `scripts/local:31 local_bottom()` is called only from `local_mount_root()`
  (`scripts/local:296`), which casper replaces (`scripts/casper:901 mountroot`,
  which runs `casper-premount`, mounts the overlay, then `casper-bottom`).
- `scripts/local-bottom/ORDER` lists only cryptgnupg-sc, cryptopensc, cryptroot,
  mdadm, ntfs_3g; `a16-live-root` was never appended to it.

Fix (`scripts/make-ubuntu-desktop-usb-iso.sh`): the hook is now
`scripts/casper-bottom/65a16-live-root` (runs after casper's own live-root setup,
with `/root` already the writable overlay), its entry is appended to
`scripts/casper-bottom/ORDER`, the builder refuses to continue if that ORDER
file is missing, and the artifact check asserts both the hook file and the ORDER
entry. The same fix restores the custom module/firmware handoff into the live
root, which had been silently broken the same way.

New artifact: `…-live-media-harvest3.iso` (VARIANT_SUFFIX `-harvest3`). The
stale `…-harvest.iso` and `…-harvest2.iso` must not be flashed — the first is
harvest-dead (hook phase), the second boots and installs the unit but its
trigger never fires (below).

### The unit was also gated behind multi-user (same session)

With the hook in the right phase, a QEMU run of `…-harvest2.iso` (kernel +
initramfs booted directly on `-machine virt`, ISO as CD-ROM, a FAT volume
carrying `EFI/Microsoft` as the sink) shows the hook now works: the live root
has `/usr/local/sbin/a16-harvest`, `/usr/lib/modules/7.3.0-rc3-next-20260914`
(the module handoff, previously dead too) and
`/etc/systemd/system/a16-harvest.service` — `systemctl status` reports
"loaded … enabled" but "Active: inactive (dead)" with `Job: 177`, and
`systemctl list-jobs` explains why:

```
177 a16-harvest.service      start waiting
10  multi-user.target        start waiting
212 snapd.seeded.service     start running
214 cloud-final.service      start waiting
196 casper-md5check.service  start waiting
```

`After=multi-user.target` means "wait until the *whole* multi-user transaction
is done", and on this medium that transaction includes snapd seeding,
cloud-init and `casper-md5check` hashing a 4.7 GB ISO. On hardware multi-user
was reached at ≈169 s (so the old unit would have fired ≈194 s), but nothing
guarantees it: in QEMU it was still "start waiting" ten minutes after the login
prompt. Trigger the harvest with a systemd timer instead
(`OnBootSec=90`, `AccuracySec=1s`, `WantedBy=timers.target`), which fires at a
fixed wall-clock point after boot regardless of which units are still running.
`timers.target` is pulled in by `basic.target`, so it is active long before
multi-user.

Also fixed in the same pass: the collector tarred `summary.txt` from the work
root while the summary is written to `data/summary.txt`, so every tar exited
with "Cannot stat: No such file or directory" and the summary was missing from
the tarball (visible in the QEMU run). The tar now ships `data` only.

QEMU harness kept for reuse (no hardware needed):
`.diag/qemu-harvest-smoke-dt2.sh` (bidirectional serial socket; it extracts
`/casper/vmlinuz` and `/casper/initrd` from the ISO into `.diag/qemu-harvest/`
on first use and aborts if either is missing) plus
`.diag/qemu-serial-drive.py` (log in as `ubuntu`, run commands, save the
transcript). Use `-cpu max` and the DT path: with `acpi=force` the guest panics
in `time_init` ("Unable to initialise architected timer"). A manual
`sudo /usr/local/sbin/a16-harvest` in that guest wrote
`a16-harvest-<stamp>.tar.gz` (23 kB) to the sink, proving the collector and sink
logic are sound.

Verified end-to-end on `…-harvest3.iso` in the same harness, with **no
interaction at all**: the serial log shows
`Started a16-harvest.timer - A16 bring-up harvest timer.` →
`Starting a16-harvest.service` → the full `================ A16 HARVEST
================` summary on the console →
`sink : internal EFI system partition (/mnt/a16-sink)` /
`tarball : full 21701 B / text-only 18344 B` →
`Finished a16-harvest.service`, and the sink FAT image then holds
`a16-harvest-20260916-115811.tar.gz` whose contents include `data/summary.txt`
(the tar fix). It fired at ~90 s of runtime, mid-boot, before `multi-user.target`
was reached — exactly the behaviour wanted on hardware.


## First real hardware harvest (2026-09-16)

The reboot at 08:04-08:18 produced the first real harvest: the default ACPI
diagnostic console entry booted, the timer fired ~90 s in, and
`a16-harvest-20260728-124912.tar.gz` (146,051 B) landed on the internal ESP.
Copied out with `a16-read-log.ps1`, unpacked in `.diag/harvest-hw/`. Trust the
content, not the name: the live session cannot read a hardware clock
(`probe of rtc-efi.0 with driver rtc-efi returned 19`,
`acpi-tad ACPI000E:00: hctosys: unable to read the hardware clock`), so it
stamped the file `20260728-124912`.

`cmdline.txt` confirms the intended entry ran (`acpi=force console=tty0
earlycon=efifb keep_bootcon ... module_blacklist=msm`), and the identity block
confirms the machine/kernel (`Zenbook A16 UX3607OA`, BIOS `UX3607OA.312`,
`7.3.0-rc3-next-20260914`).

Memory, as the firmware hands it to an ACPI boot (`data/iomem.txt`):

- 20 `System RAM` ranges, total 31.604 GiB (33,934,577,664 B).
- Two banks: low `0x81a60000-0xffdfffff` (~1.5 GiB) and high
  `0x880000000-0x8be5f9fff` (~0.98 GiB) plus `0x8c0000000-0xfffffffff` (~29 GiB).
  Nothing at all is described between 4 GiB and 34 GiB.
- Carveouts inside those ranges total 5.04 GiB (largest
  `0xed4c00000-0xfabffffff`, 3.36 GiB), so net unreserved RAM is **26.57 GiB**
  (28,528,005,120 B). MemTotal will be a little lower still.
- Exactly **16.00 GiB** sits at `0x8800000000-0x8bffffffff` (544-600 GiB) marked
  `reserved` — the same window Canonical's GRUB `cutmem 0x8800000000
  0x8fffffffff` targets. 31.60 + 16.00 = 47.60 GiB, matching Windows'
  `TotalPhysicalMemory` (51,127,103,488 B = 47.62 GiB) to within 12 MB: the
  machine has 48 GiB and this boot mode holds one third of it back in that
  window. Declaring that window in a DT `/memory` node is the obvious (and
  risky — it is firmware-reserved) way to ask for the full 48 GiB.
- `/sys/firmware/fdt` is present and only 729 bytes: the firmware publishes its
  own memory-less DT in the EFI configuration table, which is what the
  `firmware/loader-provided DT` entry sees.
- Input is confirmed unchanged in ACPI mode: no I2C adapters, no HID devices, no
  GPIO controllers; the only input device is the ACPI `Lid Switch`.

Gap found in the collector (fixed after this harvest): the `== memory ==`
section read `/var/log/dmesg`, which Ubuntu live images do not have, so
MemTotal/MemAvailable were missing. The collector now reads `/proc/meminfo`
directly, pipes the memory-ish lines of `dmesg`, and copies `/proc/meminfo` into
the tarball as `data/meminfo.txt`.


## Stock 26.10 daily install attempt — apt rejects the medium's own repo (2026-09-16)

The maintainer flashed the **stock Canonical daily**, not a rebuilt A16 image:
`/mnt/c/Users/cates/Downloads/stonking-desktop-arm64_lat.iso` (4,236,587,008 B,
`sha256 4b682a946b048b8ea78dcb24bc2e42e036ccef0db280ab9d7aaffce73ec6dd1e`,
re-hashed 2026-09-16 09:30), written 2026-09-16 ~09:03 per
`/mnt/c/Users/cates/Downloads/Rufus/rufus.log`
(`Using image: stonking-desktop-arm64_lat.iso (3.9 GB)`). The install failed.

Two facts about this attempt matter for the whole plan:

- **The stock Ubuntu 26.10 arm64 daily boots this machine into a live GNOME
  session and runs its installer** — the panel shows the desktop wallpaper, the
  installer UI and apport dialogs, and the run got as far as an installed target
  being configured. Every "black screen, no output" failure recorded above was a
  *rebuilt* image; the daily is not one of them.
- The install **aborts while curtin configures apt inside the target**, and
  `ubuntu-desktop-bootstrap` then dies: apport reports
  `Title: ubuntu-desktop-bootstrap crashed with CalledProcessError`,
  `SourcePackage: ubuntu-desktop-bootstrap` (snap revision 668),
  `CurrentDesktop: ubuntu:GNOME`.

### Root cause: the live clock, not the medium

Fragments of the installer log, photographed at 09:17-09:23
(`/mnt/c/Users/cates/Downloads/20260916_0917*.jpg`, `…_09172*.jpg`; long lines
wrap on the panel, these are reassembled from the visible pieces):

```
Jul 28 08:56:06 ubuntu subiquity_log.5578[11431]: Get:3 file:/cdrom stonking Release.gpg [228 B]
Jul 28 08:56:06 … stonking Release: Sub-process /usr/bin/sqv returned an error code (1),
   error message is: Verifying /cdrom/…: Not live until 2026-09-08T05:20:45Z
Jul 28 08:56:06 … E: The repository 'file:/cdrom stonking Release' is not signed.
Jul 28 08:56:06 … finish: cmd-in-target: FAIL: curtin command in-target
```

Every line is stamped `Jul 28 08:56:06` although the session ran on 2026-09-16:
**the live clock is weeks behind.** This machine has no readable hardware clock
(`probe of rtc-efi.0 with driver rtc-efi returned 19`,
`acpi-tad ACPI000E:00: hctosys: unable to read the hardware clock` — see "First
real hardware harvest"), and nothing in the live session corrects it (no NTP,
no network).

apt then refuses the ISO's *own* local repository (`file:/cdrom`, suite
`stonking` — the 26.10 development suite the daily ships for its kernel
packages). That repository's metadata, extracted 2026-09-16 from both the base
ISO and this plan's `-dtmem` output and byte-identical between them
(`sha256 38ea58a03a763ed6c3333fe48afe8926fcc88310e8229f581a000cb27d535f73`):

```
Suite: stonking   Version: 26.10   Date: Tue, 08 Sep 2026  4:17:37 UTC
Valid-Until: Tue, 22 Sep 2026  4:17:37 UTC
```

The Release signature is stamped `2026-09-08T05:20:45Z`; against a clock reading
Jul 28 that signature is in the future, so `sqv` says "Not live until …", apt
treats the repository as unsigned, `apt-get update` inside the target fails, the
`in-target` step fails, and the installer aborts. Nothing is wrong with the
medium, the flash drive, the target disk, the kernel or the packaging: a correct
clock would have made the same flash install.

### What follows from it

- Retry the *same* flash with the clock set in the live session, before starting
  the installer (Ctrl+Alt+T):
  `sudo timedatectl set-ntp false; sudo date -s '2026-09-16 10:30:00'; date`
  then relaunch `ubuntu-desktop-bootstrap`. If the live session can reach a
  network, connecting it and letting `systemd-timesyncd` sync is equivalent and
  needs no typing. Set the real date: the bundled repo expires at `Valid-Until`
  2026-09-22, so a clock pushed past that fails for the opposite reason. A newer
  daily carries fresher metadata, but the wrong clock breaks apt/TLS on any
  suite.
- The clock problem follows the machine, not the medium: an installed system
  boots with a bogus date until it reaches NTP, which breaks apt's HTTPS mirrors
  and any certificate validation. Whatever gets installed here needs a time
  source.
- Every image this repo builds from this base ISO inherits the same repository
  metadata and will fail the installer's apt step the same way. A clock bootstrap
  (ship the build time on the media, set the clock from it in the live root
  before the desktop starts) belongs in the remaster — not implemented yet, see
  "Next steps".
- Flash-drive state, read 2026-09-16 09:3x from Windows/WSL without elevation:
  disk 1 `Samsung Flash Drive`, status `OK` / `Healthy`, GPT. Partition 1 =
  4,229,922,816 B at offset 32,768 (`Microsoft basic data`, ISO9660; Windows
  assigns `D:` but does not recognise the filesystem, so its contents cannot be
  read from Windows), partition 2 = 6,291,456 B EFI System at 4,229,955,584,
  partition 3 = 307,200 B at 4,236,247,040. GUID, offsets and sizes are
  identical to the source ISO's own GPT (`fdisk -l` on the ISO: disk GUID
  `4089F044-9CD6-4E70-9781-4894F0745B5E`, same three partitions), so the write is
  structurally the daily. A fourth partition of 124,082,192,384 B at
  4,238,344,192 reads "Unknown"/unrecognized: stale residue from the previous,
  larger write, not part of the daily, and it means the tail of the stick is not
  in use. Rufus enumerated the stick as `USB 2.0 device … operating at lower
  speed` at least once, which is why the live media's md5check and squashfs reads
  are slow. Byte-level verification of partition 1 needs elevation
  (`wsl --mount \\.\PHYSICALDRIVE1 --partition 1 --bare` from an admin shell,
  then hash the resulting block device against the local ISO).

## Second install attempt: clock fixed, curtin dies writing the bootloader (2026-09-16 09:44-09:54)

Same flash (`stonking-desktop-arm64_lat.iso`, written 09:03), same machine, this
time with the live clock corrected — every log line is stamped `Sep 16 09:53:55`
where the earlier attempt read `Jul 28`. The install ran all the way through
partitioning, in-target apt and the kernel (`linux-image-7.2.0-8-generic`) and
died inside curthooks' `install-grub` step:

```
curthooks/install-grub: Installing grub to target devices
  setup_grub on target /target
  Found primary UEFI ESP: partition-nvme0n1p12
  Found UEFI ESP(s) for grub install: ['partition-nvme0n1p12']
  grub debconf install_devices: /dev/disk/by-id/nvme-SAMSUNG_MZVL81T0HFLB-00BTW_S7X7NF0YC34708-part12
/usr/lib/python3.12/site-packages/curtin/util.py line 171 in subp -> ProcessExecutionError
  Command: ['unshare','--fork','--pid','--mount-proc=/target/proc','--','chroot','/target','efibootmgr','-v']
  Exit code: 2
  Stderr: EFI variables are not supported on this system.
event: executing curtin install curthooks step / curtin command install
```

`ubuntu-desktop-bootstrap` then showed "Something went wrong" and apport filed
`curthooks crashed with CurtinInstallError` (snap revision 668, Ubuntu 26.10).
Evidence: `/mnt/c/Users/cates/Downloads/Photos-1-001/20260916_0954*.jpg`
(rotated copies in `Photos-1-001-rot/`, EXIF orientation 6).

State read after the attempt (elevated Windows probe, full output
`/mnt/c/Users/cates/Downloads/a16-probe-out.txt`):

- The internal NVMe now carries the install: partition 17 = 97,952 MB GPT type
  `0fc63daf-8483-4772-8e79-3d69d8477de4` (Linux filesystem) at 854.35 GB, and
  partition 18 = 2048 MB type `0657fd6d-a4ab-43c4-84e5-0933c84b4f4f` (Linux swap).
  Windows (p14), the 450 MB ESP (p12), MSR (p13) and the two Recovery partitions
  are untouched.
- The ESP received **nothing** from this install: no `\EFI\ubuntu\`, no file
  newer than today's Windows boot activity. Its only Linux payload is April's
  `\EFI\ubuntu_snapdragon\` (shimaa64.efi, grubaa64.efi, `mmia64.efi`,
  `BOOTAA64.CSV`, a full grub-mkconfig `grub.cfg` whose entry searches root UUID
  `102b9890-bd7c-492e-bdaa-3501d0ee893d`, loads `vmlinuz-7.0.0-14-generic` and
  attaches `devicetree /x1e80100-asus-vivobook-s15.dtb`), plus July's
  `\loader\entries\opensuse-tumbleweed-*.conf` and today's harvest tarball.
- The firmware boot order is `{bootmgr}` (Windows) first, then two Linux entries
  that both point into that stale April directory:
  `{e478a527-7ff7-11f1-849c-806e6f6e6963}` → `\EFI\ubuntu_snapdragon\shimaa64.efi`
  ("Ubuntu") and `{6a51310e-5b09-11f1-92ef-be9cacaee250}` →
  `\EFI\ubuntu_snapdragon\grubaa64.efi` ("Ubuntu Linux"). Nothing points at a
  bootable system, so "won't boot" is exact — Windows boots because it is first.

Root cause of the abort: `efibootmgr` needs `/sys/firmware/efi/efivars`, and that
path did not exist inside the target chroot, so curtin aborted **before**
`grub-install` ever wrote to the ESP. This is not an Ubuntu bug and not specific
to today: the July Tumbleweed install left `\loader\entries\*` but no
`\EFI\systemd\systemd-bootaa64.efi` either — same step, same silent gap. It fits
the board's other EFI-runtime oddities (`rtc-efi` probe fails with ENODEV,
`acpi-tad` cannot read the hardware clock, hence the wrong session clock), but
whether efivarfs is absent or merely unimplemented for Linux here still has to be
confirmed in a live session (`ls /sys/firmware/efi/`, `sudo efibootmgr -v`): the
old harvest cannot answer it, because the collector ran
`efibootmgr -v > efibootmgr.txt 2>/dev/null` and discarded the message.
- `wsl --mount \\.\PHYSICALDRIVE0 --partition 17 --bare` is refused
  (`Wsl/Service/AttachDisk/MountDisk/E_ACCESSDENIED`), so the installed ext4 root
  can only be inspected from a Linux boot, not from WSL. (A removable stick worked
  earlier; a disk holding live Windows volumes does not.)

### Repair path: finish the bootloader from a live session (no reinstall)

`scripts/a16-finish-boot.sh`, copied to the internal ESP as `\A16FIX.SH`
(7,267 B, `sha256 e6e65e82322e17e9c0455c2159389092072aec266424f1a5a61b32375830f351`,
LF endings, ESP has 407 MB free). From a stock live session:

```
sudo mount /dev/nvme0n1p12 /mnt
sudo bash /mnt/A16FIX.SH
```

It auto-detects the installed Ubuntu root (mounts every ext4/xfs/btrfs partition
read-only and looks for `ID=ubuntu`), prints `ls /sys/firmware/efi/`,
`efibootmgr -v` and the target's `/boot` contents, then runs `grub-install
--target=arm64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --no-nvram`
**and** the `--removable` variant (no efibootmgr anywhere in the path), refreshes
`update-grub` (and `update-initramfs` only if no initrd exists), falls back to
hand-placing the target's own signed shim/GRUB plus a self-contained `grub.cfg`
if `grub-install` fails, tries `efibootmgr -c` only when EFI variables are real,
and writes its whole log to the ESP root as `A16BOOT.LOG` for retrieval from
Windows. It writes only to the ESP and to `/boot/grub` (+ initramfs) on the
installed root; no partition is touched.

Boot entry afterwards (Linux cannot write NVRAM here) — retarget the existing
firmware entry from Windows:

```
bcdedit /enum firmware
bcdedit /set {6a51310e-5b09-11f1-92ef-be9cacaee250} path \EFI\ubuntu\grubaa64.efi
bcdedit /set {fwbootmgr} displayorder {6a51310e-5b09-11f1-92ef-be9cacaee250} /addfirst
```

or add one from the firmware setup ("Add New Boot Option" → `\EFI\ubuntu\grubaa64.efi`
on the ESP). The `--removable` half also leaves shim/GRUB at
`\EFI\BOOT\BOOTAA64.EFI`, which the firmware can fall back to without any NVRAM
entry.

Staging done from Windows (no NVRAM change needed — the firmware already has two
entries pointing into the ESP's Linux directory):

- `\EFI\ubuntu_snapdragon\grub.cfg` replaced with a hand-written config
  (`C:\Users\cates\Downloads\a16-esp-grub.cfg`, 2,883 B,
  `sha256 4e57a60f82b4d0a3a4d73825291a89cb4d3bb0b1bad81e57fce97f2bd4e55625`, LF);
  the April grub-mkconfig output is kept beside it as `grub.cfg.april.bak`
  (`31b9f6ec…`). The same config and the April EFI binaries (shimaa64.efi,
  grubaa64.efi) were also placed in the standard `\EFI\ubuntu\` path.
  Verification output: `C:\Users\cates\Downloads\a16-esp-stage-out.txt`.
- The staged config's entries: (1) autodetect — `search --file /boot/vmlinuz-*`
  over the known kernel names, root from `probe --fs-uuid` with a
  `/dev/nvme0n1p17` fallback; (2) scan `(hd0,gptN)` for a kernel; (3) fixed
  `(hd0,gpt17)` / `7.2.0-8-generic`; (4) chainload
  `/EFI/Microsoft/Boot/bootmgfw.efi` as an escape hatch. `timeout=20`, menu
  visible, so GRUB renders on the panel before handing off.
- The firmware boot order was left alone (Windows still first) until the payload
  has booted once; the Linux entry is picked from the firmware boot menu
  ("Ubuntu Linux"). Promote it later with
  `bcdedit /set {fwbootmgr} displayorder {6a51310e-5b09-11f1-92ef-be9cacaee250} /addfirst`.

Collector fixes in the same pass (`scripts/a16-harvest.sh`): `data/efibootmgr.txt`
now records efivars presence, the efivarfs mount state, and `efibootmgr -v` with
**stderr and its exit code**; the panel summary gained an `efi vars:` line. The
empty file this harvest produced was exactly the failure mode of the old probe.

- 2026-09-16 10:2x: Stage 1 ran (see "Stage 1 result and the boot failure" below):
  grub-install and update-grub both succeeded, the ESP carries the target's own
  signed shim/GRUB plus the stub `\EFI\ubuntu\grub.cfg`, and the installed root
  has a generated `/boot/grub/grub.cfg` for its single kernel `7.2.0-5-generic`.
  But no menu entry boots: every one stops with GRUB's
  `you need to load the kernel first` (the message the `initrd` command emits
  when the preceeding `linux` command did not load a kernel). Stage 2
  (`scripts/a16-stage-esp-boot.sh` → `\A16STAGE2.SH`) now stages a boot that needs
  nothing but the ESP and collects the evidence that should explain the failure.

## Stage 1 result and the boot failure (2026-09-16 10:2x)

The stage-1 repair ran and **succeeded at its own job**. `A16BOOT.LOG` (copied off
the ESP; kept in `harvest/2026-09-16-esp/` with the ESP's configs and a README):

- installed root `nvme0n1p17`, ext4, UUID `f8e005e9-414c-4c8e-ad68-d1e9fdc208bc`,
  `/boot` holding exactly **one** kernel: `vmlinuz-7.2.0-5-generic` (23,707,016 B)
  + `initrd.img-7.2.0-5-generic` (57,201,537 B), `/boot/grub/grub.cfg` MISSING before;
- `grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
  --no-nvram --recheck` → exit 0, `Installation finished. No error reported.`, and
  the same for `--removable`;
- `update-grub` → `Found linux image: /boot/vmlinuz-7.2.0-5-generic`, os-prober
  found Windows, `done`;
- `/sys/firmware/efi/efivars` exists with **0 variables**, and the live session has
  **no `efibootmgr` binary** (exit 127) — the fact curtin died on;
- the log's own timestamps read `Tue Jul 28 12:51` because that live session had no
  readable clock (same reason the July harvest tarball is stamped `20260728-124912`);
  the session's kernel was `7.0.0-14-generic`, i.e. the stock daily, as expected.

### Why the panel showed the installed system's menu, not the hand-written config

The hand-written config staged into `\EFI\ubuntu_snapdragon\grub.cfg` is **dead
code**. `strings` on the ESP's binaries shows the embedded config prefix of
`\EFI\ubuntu_snapdragon\grubaa64.efi` is `/EFI/ubuntu` (and it is byte-identical to
the `\EFI\ubuntu\grubaa64.efi` that grub-install wrote today, sha256 `e9c439d2…`),
so a GRUB loaded from either firmware Linux entry reads `\EFI\ubuntu\grub.cfg` —
the 117 B stub pointing at the installed root's generated config. Only the
`--removable` binary is different (`\EFI\BOOT\grubaa64.efi`, 2,533,256 B, prefix
`/boot/grub`). Firmware order (unchanged, no NVRAM writes possible from Linux):
`{bootmgr}` Windows, then `{e478a527…}` "Ubuntu" → `\EFI\ubuntu_snapdragon\shimaa64.efi`,
`{6a51310e…}` "Ubuntu Linux" → `\EFI\ubuntu_snapdragon\grubaa64.efi`, and
`{99907c04…}` "ubuntu (SAMSUNG …)" → `\EFI\ubuntu\shimaa64.efi`.

### What is still unexplained

GRUB reads its config off the ext4 root (the stub + the generated config prove the
search/UUID path and ext4 reads work), yet `linux /boot/vmlinuz-7.2.0-5-generic`
does not put a kernel in memory for any entry, so `initrd` reports
`you need to load the kernel first`. Candidates the stage-2 diagnostics
(`A16DIAG2.TXT`, `P17-GRUB.CFG` on the ESP) are meant to settle: the kernel file's
format/size as the installer left it, whether the target's
`/boot/grub/arm64-efi` module set is complete (`gzio.mod` etc.), the ext4 feature
set (`metadata_csum_seed`/`orphan_file`), and what the generated entries literally
contain. The diagnostics menu entry also echoes `$prefix`/`$cmdpath` on hardware,
which confirms on the machine which config a GRUB loaded from each firmware entry
really reads.

## The agent moves onto the A16 (2026-09-16)

There is no second machine while the A16 runs Linux: Windows, WSL and this clone are
offline, so hardware facts can only be read live or reconstructed afterwards from
photos and harvested tarballs. Running Hermes *on* the A16 removes the round trip —
it can read `dmesg`, `/sys`, the ACPI tables and the ESP in the same session.

Payload built and verified in WSL, carried on the USB stick
(`/home/jc/a16-export/payload/`, 260 MB):

| artifact | size | why |
|---|---|---|
| `hermes-backup-a16.zip.gpg` | 37 MB | Hermes state: `config.yaml`, `.env`, `auth.json`, `shared/nous_auth.json`, skills, memory, cron, `state.db`. `hermes backup` produced 462 files / 93.9 MB, excluding `hermes-agent/` and caches. gpg AES-256 symmetric because it carries the `.env` keys and OAuth tokens; the passphrase file stays on the Windows side (`C:\Users\cates\Downloads\a16-hermes-backup-key.txt`), never on the stick. Round-trip verified: decrypt → sha256 identical → `zipfile.testzip()` None. |
| `a16build.bundle` | 13.6 MB | `git bundle` of `feature/tumbleweed-a16-live-iso` (`git bundle verify`: complete history) — the offline path for the commits that were unpublished at the time. |
| `zenbook-a16-7.3.0-rc3-next-20260914.tar.zst` | 195 MB | `Image` + 9,980 module files + 10,377 dtbs + metadata, so the installed system can run this kernel with no rebuild. |
| `a16-local-firmware/`, `install.sh`, `*.cfg`, `custom-iso.sha256` | 23 MB | sources that live outside the repo, plus a cached installer for a retry. |
| `a16-triage.sh` | 8 KB | the live collector below. |
| `sha256sums.txt` | | verify on arrival (`sha256sum -c`) before using anything. |

Deliberately NOT carried: `local-wsl-build/` (44 GB) and `.diag/` (43 GB) — untracked
scratch, regenerable, and a native build on the A16 is the better path.

On the A16:

```bash
git clone -b feature/tumbleweed-a16-live-iso https://github.com/jc372/A16Build.git ~/A16Build
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
gpg -d hermes-backup-a16.zip.gpg > /tmp/hb.zip && hermes import /tmp/hb.zip && rm /tmp/hb.zip
hermes doctor && hermes chat -q "hostname and uname -r"
sudo bash /media/$USER/<STICK>/a16-triage.sh   # writes a16-triage-<host>-<stamp>.tar.gz to the stick
```

`a16-triage.sh` records stdout, stderr and the exit code of every probe (a silent
probe reads as "nothing found") and never fails hard: full `dmesg`/journal,
`/proc/iomem`, `/proc/meminfo`, `/sys/firmware/efi/**` + `efibootmgr -v`, ACPI device
status and which driver claims `QCOM0F10`/`QCOM0F0C`, i2c/hid enumeration, DRM/panel
state, `ath12k` + firmware presence, the DSP-firmware checklist, input devices,
rfkill/ip, thermal/battery, NVMe. First question it settles: **whether
`/sys/firmware/efi/efivars` exists at all** — the fact curtin died on and the July
harvest discarded with `2>/dev/null` — and whether the input devices' I2C controllers
are still unclaimed.

Two consequences to keep in mind:
- `state.db` becomes a **copy**: sessions on the A16 and in WSL diverge. Conclusions
  belong in `PLANS/` + git, not in chat.
- The A16 install is the current release (`install.sh`); this WSL side is v0.21.3
  (upstream `eaef5237`). Drift is expected — `hermes doctor` after the import.

## Windows-side firmware extracted for the Linux side (2026-09-16)

The installed Linux system is missing Wi-Fi, sound and HDMI, and the vendor blobs
for those blocks exist only on the Windows side of this machine. Extracted them
out of the Windows DriverStore and published them in the repo, so the Linux side
gets them with a `git pull` and no second machine.

- Tooling: `scripts/extract-windows-a16-firmware.sh` (re-runnable; `DRY_RUN=1`,
  `SRC=`, `OUT=`, `INCLUDE_DSP_MODULES=1`). It walks every Qualcomm driver package
  whose name carries the SoC id (`*8480`), groups the payload by subsystem, dedupes
  by content hash, skips driver code (`.sys/.inf/.cat/.dll/.exe`), Hexagon userspace
  module trees (`ADSP/`, `CDSP/`, `HTP/` `*.so`) and the `.pmd` AI models, and writes
  `MANIFEST.tsv` (per file: group, package, size, sha256, status, full Windows source
  path) plus `sha256sums.txt`.
- Payload: `firmware/windows-driverstore-2026-09-16/`, **326 files, 87 MiB**,
  `sha256sum -c sha256sums.txt` → 327 OK (326 payload + README). Every hash was
  computed from the Windows source, so the check also proves the copies survived the
  `/mnt/c` mount — the corruption mode that has bitten this project twice.
- Committed as `f8514c8` and pushed to `origin/feature/tumbleweed-a16-live-iso`
  (verified with `git ls-remote`, not from the push output). A 30,492,293-byte zip of
  the same tree (`sha256 c85357f3…`) is at `/home/jc/a16-export/` and copied+hash-verified
  into `C:\Users\cates\Downloads\a16-windows-firmware-2026-09-16.zip` (`Get-FileHash`
  matched) for the carry-it-on-a-stick route.
- The four ADSP/CDSP images already committed under
  `firmware/qcom/glymur/ASUSTeK/UX3607OA/` are **byte-identical** to the Windows files
  (recorded in the manifest as `already-in-repo`, not copied twice) — that directory's
  provenance is now confirmed.

### The Wi-Fi part is not a WCN7850 — this changes what to chase

Verified from the running Windows install (`Win32_PnPSignedDriver`: the bound
`C:\Windows\INF\oemNN.inf` was sha256-matched against the DriverStore package's own
`.inf`, so package→device is a match, not an inference):

- Wi-Fi is **Qualcomm FastConnect C7700 NCM820A, `PCI\VEN_17CB&DEV_1112`**, driver
  685.13804.110.0, `oem177.inf` = `qcwlancol8480.inf_arm64_d440e12aca6ddc77`. Its BDFs
  are named `bdwlan_qcc2072_1p0_ncm820A*.elf` (plus a per-OEM `…_AC_Shrimp.elf`), the
  firmware image is `wlanfw.bin`, with `phy_ucode.elf`, `aux_ucode.elf`, `regdb.bin`,
  `Data.msc`.
- The other staged WLAN package, `qcwlanhmt8480` (**WCN785x**: `wlanfw20.mbn`,
  `phy_ucode20.elf`, `bdwlan_wcn785x_2p0_ncm825*/ncm865a*`), is bound to **nothing
  present** on this machine. The earlier note in this plan that the A16's Wi-Fi is
  "ath12k/WCN7850" came from that staged package, not from the hardware. It is kept in
  `wlan/` as reference only.
- linux-next (`next-20260914`, in `local-wsl-build/linux-next`) **already claims this
  device**: `drivers/net/wireless/ath/ath12k/wifi7/pci.c` defines
  `QCC2072_DEVICE_ID 0x1112` in `ath12k_wifi7_pci_id_table[]`, sets
  `ATH12K_HW_QCC2072_HW10` and a QCC2072-specific window register, and its hw params
  name the firmware directory **`QCC2072/hw1.0`** (`board_size` 256 KiB,
  `m3_loader = ath12k_m3_fw_loader_driver`, `download_aux_ucode = true` — which is why
  the Windows package ships `aux_ucode.elf`). So the Linux-side path is
  `ath12k/QCC2072/hw1.0/`, fed from `wlanfw.bin` / `bdwlan*.elf` / `regdb.bin` /
  `phy_ucode.elf` / `aux_ucode.elf`; these are source material for the driver's own
  filenames, not drop-in replacements.
- **The A16 device tree has no Wi-Fi node at all.** `glymur-asus-zenbook-a16-ux3607oa.dts`
  includes `glymur.dtsi` only; the CRD/HP/Lenovo boards carry
  `wifi@0 { compatible = "pci17cb,1107"; … }` (1107 = WCN7850). Missing: a node with the
  right compatible (`pci17cb,1112`), its supplies and its PCIe root port — i.e. the
  Wi-Fi gap on this board is (at least) a DT gap, not only a blob gap. Worth checking on
  hardware what `lspci -nn` reports for 17cb:1112 and whether `ath12k` binds at all in
  the current boot before building any image around firmware.
- **linux-firmware may already ship the QCC2072 firmware.** The `ath-20260812`
  linux-firmware pull request ("ath12k: QCC2072 hw1.0: update to
  WLAN.COL.1.0.c2-00228") carries `ath12k/QCC2072/hw1.0/firmware-2.bin`
  (7,148,724 B in that revision). Source: the mailing-list pull request — **not**
  verified against a distro package from here. First Wi-Fi check on the A16 is therefore
  `ls -la /lib/firmware/ath12k/QCC2072/hw1.0/` and the age of the `linux-firmware`
  package; if the files are there, the Windows blobs are irrelevant and the gap is the
  DT.
- QCC2072 hw params read from the tree's `hw.c`, worth having when the DT node is
  written: `rfkill_pin/cfg/on_level = 0` (no RFKILL command is sent — RF-kill is tied to
  `WLAN_EN` on this part), `iova_mask = 0`, `bdf_addr_offset = 0`, `supports_aspm =
  true`, `dp_primary_link_only = false` (multi-link allowed, unlike WCN7850),
  `download_aux_ucode = true`.
- To answer all of it in one shot, `scripts/a16-triage.sh` is now committed (it was
  only in the export payload before) and extended for this: it gained an `ath-pci.txt`
  probe (every `17cb` device, its bound driver, `modinfo ath12k`), its ath12k firmware
  probe now lists `QCC2072/hw1.0` as well as `WCN7850/hw2.0`, and the panel summary
  reports both directories plus the count of `17cb` PCI devices. Run it as
  `sudo bash scripts/a16-triage.sh` in the installed session; it writes one tarball.
  Exact reading of the possible answers is in the firmware directory's README,
  "First checks on the Linux side".
- The device→driver→package table in that README is backed by the full inventory dump
  committed beside it (`host-inventory/windows-device-inventory.txt`, all present
  ACPI/PCI devices with class, status, instance id and bound INF, plus the PowerShell
  that produced it) — so the mapping can be re-derived without another Windows session.

### Sound, HDMI and the rest of the mapping

- Sound is **Aqstic/SoundWire**, no WSA/WCD codec blob: the payload is
  `qcadsp8480.mbn` + `adsp_dtbs.elf` (already in the repo) plus `acdb_cal.acdb` (524,502 B
  — the machine's audio calibration database, under `adsp/qcacsp_crd8480…/`),
  `ADCMResources.bin`, and the endpoint definitions in `platform/dax3_ext_qc…/`
  (`AUCD_DEV_…_ADCM_SUBSYS_….xml`). Packets are served by `oem142.inf` = `qcasd8480`
  (ACX audio stream driver), with `qcadcm8480` (`oem81.inf`, Aqstic Audio DSP and
  Calibration Manager), `qcascd8480` (`oem66.inf`, SoundWire controller), `qcaucd8480`
  (`oem106.inf`), `qcadx8480` (`oem6.inf`, AudioDriverX). The SoundWire SDCA endpoints
  (`MAN_0217`) themselves are driven by Microsoft's `sdcaclass.inf`, not a vendor package.
- HDMI has **no separate bridge driver package** on this machine: the panel is
  `DISPLAY\SDC422C` on the Adreno GPU package (`oem153.inf` = `qcdx8480`), and the only
  display-adjacent firmware present is HDCP — `hdcp1.mbn`, `hdcp2p2.mbn`, `hdcpsrm.mbn`,
  `pr_3_wp.mbn` in `display-hdcp/` (from `qctreeextqcom8480`). If HDMI needs a vendor
  blob at all, it is one of these; the DP/PHY side is a driver/DT matter.
- Also captured for later: camera (Spectra ISP, 27 MiB incl. per-sensor tuning and
  secure-ISP images), `gpu-video/` (`qcav1e8480.mbn`, `qcvss8480.mbn`, `evass.mbn`),
  Bluetooth patchram/NVM (`hmtbtfw20.tlv`/`hmtnv20.*` and `clnbtfw10.tlv`/`clnbtnv10.*`
  — CLN is the likely one for this C7700 part), sensor configs, and the platform packages.
- Deliberately not taken, with the command to get them if ever wanted: the Hexagon
  userspace module trees and `.pmd` AI models (~190 MiB) — see the extraction's README.

What is **not** established: that any of this makes Wi-Fi / sound / HDMI work on the
Linux side. Nothing has been tested against these blobs yet; the README labels each
claim as verified-on-the-machine, read-from-the-tree, or untested.

## History

- 2026-09-16 (15:4x): **Wi-Fi works.** The QCC2072's only missing piece was the board-data
  key: the distro `board-2.bin` carries four keys and none is this machine's
  (`…subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255[,variant=UX3407Q]`), and
  `qmi-board-id=255` means the chip's OTP carried no board id. Wrapped the machine's own
  vendor image `bdwlan_qcc2072_1p0_ncm820A.elf` (from its Windows package `qcwlancol8480`)
  under that key with QCA's `ath12k-bdencoder` and installed the result:
  `firmware/ath12k-board-2-qcc2072-e14f/board-2.bin`, 526,972 B, sha256 `314e2d57…`,
  reproducible with `scripts/make-a16-qcc2072-board-2.sh` (same hash). Verified on hardware
  after a reboot: 0 `failed to fetch board data` lines, `wlP4p1s0` up, 50+ APs visible,
  29 Mbit/s measured, LAN gateway reachable. Also corrected an assumption: no DT Wi-Fi node
  is needed — PCI enumeration brings the part up on the DT boot. Kept the harness for the
  other 24 vendor images (`scripts/a16-wifi-bdf-test.sh --dry-run|--verify`) and the lesson
  list in `notes/2026-09-16-hermes-wifi-board-data.md`.
- 2026-09-16 (14:4x): **Windows-side firmware extracted and published.** Built
  `scripts/extract-windows-a16-firmware.sh` (grouping, hash-dedupe, manifest) and
  committed `firmware/windows-driverstore-2026-09-16/` — 326 files / 87 MiB,
  `sha256sum -c` 327 OK, four ADSP/CDSP images already in the repo recorded as
  `already-in-repo` instead of duplicated. Pushed as `f8514c8` and confirmed on
  `origin/feature/tumbleweed-a16-live-iso` by `git ls-remote`; a 30 MB zip
  (`c85357f3…`) sits in `/home/jc/a16-export/` and hash-verified in Windows Downloads.
  Findings recorded with it: the A16's Wi-Fi is a **FastConnect C7700 / NCM820A
  (`17CB:1112`, package `qcwlancol8480`)**, *not* the WCN7850 the plan assumed (that
  package is staged and bound to nothing); linux-next's ath12k already knows `0x1112`
  and loads `QCC2072/hw1.0`; and the A16 DTS has **no Wi-Fi node**, so the gap is at
  least partly device-tree. Sound needs no codec blob (ADSP image + `acdb_cal.acdb`);
  the only display firmware present is HDCP. Every claim labelled
  verified/read-from-tree/untested in the firmware directory's README.
- 2026-09-16 (11:5x): **Windows Downloads cleaned, and the offline copy of the agent
  built for the A16.** Cleanup freed 35.6 GB (C: 34 -> 69 GB) by deleting eight
  images only after verifying what replaced them: six were byte-identical duplicates
  of WSL masters (`harvest`, `harvest2`, `harvest3`, `dtmem`, `ubuntucfg`, `stockctl`
  — sha256 compared on both sides, e.g. `500af942…` for `harvest`), one was a verified
  duplicate of `/home/jc/A16_Gemini/ubuntu-snapdragon-a16-custom.iso`, and one was the
  Aug-14 resolute copy already recorded above as unverified and superseded. Orphan
  `.sha256` sidecars went with them. Kept: the current verified ISO, the resolute
  `-diag-efifb` known-good rebuild, `stonking-desktop-arm64_lat.iso`, the Fedora line
  and the stock dailies. Two equal-size pairs turned out to be different files and
  were kept — `…va48-stonking-modular-drm.iso` (`64038956…`) vs `…-live-media.iso`
  (`0988465f…`), and `stonking-desktop-arm64 (1).iso` (`9e762e34…`) vs
  `ubuntu-baseline-stonking-desktop-arm64.iso` (`3f02290d…`); the first may be another
  instance of the `/mnt/c` corruption mode recorded above and is unresolved.
  Offline agent copy: the A16's installed Linux user is `jc` (home `/home/jc`), so the
  absolute venv interpreter path lines up and no network install is needed. Payload
  `C:\Users\cates\Downloads\a16-payload` (737 MB, 17 files, `VERIFY OK`) holds
  `hermes-program-jc.tar.gz` (1.35 GB raw, 441 MB gzipped: `hermes-agent` incl. venv
  and `.git`, `.hermes/bin`, `.local/share/uv/python`, `.cua-driver`, `.local/bin`),
  the plaintext state zip, `a16-hermes-setup.sh` (verifies, unpacks, moves any existing
  install aside, `hermes import --force`, PATH, `hermes doctor`, writes its log back to
  the stick) and `INSTRUCTIONS-A16.md`. Verified before shipping by extracting the
  archive into a scratch root with `HERMES_HOME` redirected: the interpreter ran
  (3.11.16), core imports loaded (openai 2.24.0), and the extracted tree reported
  `Hermes Agent v0.21.3 (2026.9.14) · upstream eaef5237`. The operator has copied the
  payload to a USB stick. Browser tools were left behind (~1 GB of Playwright
  browsers, useless for hardware work).
- 2026-09-16 (11:2x): Installed system boots (operator report) and the agent moves
  onto it. Export payload built in WSL — Hermes state 37 MB gpg-encrypted, git bundle
  13.6 MB, kernel bundle 195 MB, `a16-triage.sh` collector — and verified there (gpg
  round-trip sha256 match, zip `testzip()` clean, `git bundle verify`, `bash -n` on
  the script). Branch pushed to origin, publishing 22 commits that existed only in
  this WSL clone. Reported hardware gaps in the installed session: Wi-Fi, sound,
  internal keyboard + touchpad; network via a USB-C dock. The 87 GB of untracked
  build scratch (`local-wsl-build/`, `.diag/`) was deliberately not carried.
- 2026-09-16 (10:2x): Stage 1 of the bootloader repair ran and worked
  (`grub-install` both layouts exit 0, `update-grub` wrote the target's config for
  kernel `7.2.0-5-generic`), yet no menu entry boots: every one reports GRUB's
  `you need to load the kernel first`, which the `initrd` command emits after a
  `linux` that did not load a kernel. Established from the ESP's own files that the
  hand-written config in `\EFI\ubuntu_snapdragon\` is dead code — both firmware
  Linux entries run a `grubaa64.efi` whose embedded prefix is `/EFI/ubuntu`, so
  GRUB reads the 117 B stub there and then the installed system's generated
  `\boot\grub\grub.cfg` off ext4 (which proves ext4 + uuid search work). Staged
  `scripts/a16-stage-esp-boot.sh` → `\A16STAGE2.SH`: copies kernel, initrd and the
  `arm64-efi` module set onto the ESP, writes a four-entry menu (ESP-staged kernel,
  the generated config, a diagnostics entry that echoes `$prefix`/`$cmdpath`, and
  Windows) to every config location a GRUB on this ESP reads, dumps
  `A16DIAG2.TXT`/`P17-GRUB.CFG` for Windows-side reading, and backs up the three
  configs it replaces into `A16ESP-BACKUP/`. ESP evidence committed under
  `harvest/2026-09-16-esp/`.
- 2026-09-16: Second install attempt, clock fixed → the installer got
  all the way to curthooks and died writing the bootloader: curtin ran
  `efibootmgr -v` in the target chroot, which exited 2 with `EFI variables are not
  supported on this system.` → `curthooks crashed with CurtinInstallError`. The
  install left partitions 17 (95.6 GiB Linux filesystem) and 18 (2 GiB swap) on
  the internal NVMe but **nothing** on the ESP and no boot entry, so there is
  nothing to boot (Windows boots only because it is first in the firmware order).
  The July Tumbleweed install shows the same gap, so this is a machine-wide
  blocker, not an Ubuntu bug. Repair prepared and staged on the internal ESP:
  `scripts/a16-finish-boot.sh` → `\A16FIX.SH` (auto-detects the installed root,
  `grub-install --no-nvram` + `--removable`, `update-grub`, log to `A16BOOT.LOG`),
  plus a boot-entry retarget from Windows via `bcdedit`. Also fixed the
  collector's silent `efibootmgr` probe. `wsl --mount` of the internal disk's
  partition is denied, so ext4 inspection needs a live boot.
- 2026-09-16: Stock 26.10 daily install failed on the live clock. The
  maintainer flashed the stock `stonking-desktop-arm64_lat.iso` (not a rebuild),
  which booted the A16 to a live GNOME session and ran ubuntu-desktop-bootstrap
  until the in-target apt step; apt rejected the medium's own `file:/cdrom
  stonking` repository because `sqv` found its signature "Not live until
  2026-09-08T05:20:45Z" against a clock stamped `Jul 28 08:56:06`, i.e. the live
  session's clock is weeks behind (no readable RTC on this machine, no NTP), and
  the installer died with `CalledProcessError`. Fix is a clock set in the live
  session (recipe above); the medium and the flash drive are sound. See "Stock
  26.10 daily install attempt" for the log fragments, the repo metadata, and the
  drive check.
- 2026-09-16 (later): First real hardware harvest. The `-harvest3` image booted
  the default ACPI diagnostic console entry, the timer fired ~90 s in and the
  tarball landed on the internal ESP (146,051 B, mis-stamped `20260728-124912`
  because the live session has no readable hardware clock). Data committed under
  `harvest/2026-09-16/`. Memory answer: 20 `System RAM` ranges totalling
  31.604 GiB, 5.04 GiB of carveouts inside them (net 26.57 GiB), and exactly
  16.00 GiB reserved at `0x8800000000-0x8bffffffff` — 31.60 + 16.00 = 47.60 GiB
  ≈ Windows' 47.62 GiB, i.e. 48 GiB installed with a third held back from an
  ACPI boot. Baked the net ranges into `a16-memory-acpi.dtb` and built the
  `-dtmem` image (default entry = DTB diagnostic console) as the next hardware
  test. Collector gap fixed: `== memory ==` read a `/var/log/dmesg` that live
  Ubuntu does not have, so `MemTotal`/`MemAvailable` were missing; it now reads
  `/proc/meminfo` and ships `data/meminfo.txt`.
- 2026-09-16: Harvest image booted on hardware and harvested nothing. Two build
  bugs found and fixed: (a) the live-root hook sat in `local-bottom`, a phase
  casper never runs; (b) the harvest unit was ordered `After=multi-user.target`,
  which on this medium can stay un-reached for minutes — a QEMU run of the
  phase-fixed image showed the hook working (unit installed, module handoff
  working) but the unit stuck in "start waiting" behind multi-user.target, with
  `snapd.seeded`/`cloud-final`/`casper-md5check` still pending. The hook now
  lives in `casper-bottom` (registered in its `ORDER`) and installs a systemd
  timer (`OnBootSec=90`) instead of a multi-user-gated unit; the collector's tar
  no longer references a misplaced `summary.txt`. See the section above. Photos:
  `/mnt/c/Users/cates/Downloads/20260916_064842.jpg` (first boot, ~49 s, late
  initcalls) and `…_065320.jpg` / `…_065320 (1).jpg` (second boot: multi-user at
  ≈169 s, `casper-md5check` at ≈190 s). ESP checked with an elevated probe of
  disk 0 partition 12: no `a16-*` anywhere.
- 2026-09-16: Corrected the `cutmem` note in "Next steps": the actual GRUB line
  is `cutmem 0x8800000000 0x8fffffffff` (32 GiB at 544-576 GiB), not a 2 GB
  window, and it sits entirely above the 48 GiB top of RAM, so the harvest's
  `System RAM` lines will be complete. Verified against the built artifact's
  `/boot/grub/grub.cfg` (`xorriso` extraction: `timeout=30`, `default=2`,
  entry 2 = ACPI diagnostic console with `earlycon=efifb keep_bootcon`) and
  against the Windows-side `meminfo.txt` (Bank 0 = 51,539,607,552 B).
- 2026-09-15 (late): Third hardware session. ACPI entries booted (graphics
  fastest), DTB entries still dead, no internal keyboard/touchpad. Root causes
  established offline: (a) ACPI mode cannot enumerate the input devices because
  the firmware's `QCOM0F10` (I2C) and `QCOM0F0C` (GPIO) IDs match no Linux
  driver, so no I2C adapter is created; (b) the shipped DTB has no `/memory`
  node, so GRUB's `devicetree` handoff gives the kernel no RAM at all. Added the
  `A16_HARVEST` collector (self-reporting live sessions) and the
  loader-provided-DT menu entry, and built the first harvest image.
- 2026-09-15 (evening): Second hardware attempt against the correct ISO still
  produced a black screen with no output. Established that the flashed image
  was this plan's build, that the GRUB configuration is identical to the
  known-good one, and that the diagnostic command lines could never have shown
  anything (bare `earlycon` resolves to nothing; `FB_EFI` is unset so fbcon
  needs DRM). Added `DIAGNOSTIC_CONSOLE`/`DEFAULT_MENU_ENTRY` knobs and built
  two diagnostic ISOs with `earlycon=efifb` — one with the current kernel, one
  rebuilding the known-good Aug-14 kernel/base combination. Added a
  `STOCK_ENTRIES` knob so the image can also carry the stock Ubuntu kernel and
  initramfs as two control entries, and built the combined `-stockctl` image.
- 2026-09-15: First hardware boot attempt failed (black screen, no output,
  reboot).
  Investigated and traced to the wrong image being on the USB: the flashed ISO
  is the unrelated `/home/jc/A16_Gemini/a16Build.sh` output, not this plan's
  verified ISO. Full evidence in "Boot attempt root cause" above.
- 2026-09-15: Started from a new empty `/home/jc/A16Build` directory.
- 2026-09-15: Audited current linux-next against all three historical patch
  payloads and removed patch application from this build path.
- 2026-09-15: Completed the no-patch kernel build, packaging, Ubuntu initramfs
  rebuild, ISO remaster, and embedded-payload verification.
