# Nightly ASUS Zenbook A16 (UX3607OA) Linux kernels

This repository builds an **ARM64 development kernel** from `linux-next`, then applies the Qualcomm ASUS Zenbook A16 / Snapdragon X2 (Glymur) patch series and only explicitly listed missing prerequisites. It starts with Fedora Rawhide's current AArch64 kernel configuration, forces the early-boot Glymur supplier and peripheral drivers built in, and fails the build if any required option is lost. It publishes an `Image`, DTBs, modules, and build diagnostics in a compressed GitHub Actions artifact.

It is designed for testing upstream enablement. It is not an installer, not a recovery image, and not a replacement for the Windows boot chain.

## Configure the patch stack

`config/series.env` holds the A16 mailing-list Message-ID. Update it whenever an updated series is posted. Prerequisites belong in `DEPENDENCY_SERIES_MSGIDS` **only after confirming they are absent from the current linux-next tree**. Keep the list empty otherwise.

`A16_PATCH_SELECTION` records the numbered patches that are still missing from the configured A16 series. It is set to empty because linux-next has now integrated the entire current series (binding, board DTS, and the QSEECOM firmware allowlist) as of 2026-08-14; `scripts/apply-series.sh` skips whatever the configured tree already contains, so an empty selection stays correct for both the pinned known-good revision and a newer unpinned tree. Set it to specific patch numbers if a future series is only partially integrated, after checking the latest linux-next integration.

`scripts/apply-series.sh` downloads each series with `b4`, splits it into individual patches, and checks every patch before applying it:

- applies a clean patch with `git am --3way`;
- skips a patch whose reverse applies cleanly (it is already present);
- stops if a patch is neither clean nor already present.

It never uses `git am --skip`, `--ignore-space-change`, or force application. That makes reruns safe and exposes genuine dependency conflicts.

## GitHub Actions

The workflow runs nightly at 03:23 UTC and supports **Run workflow** for an on-demand build. A blank revision uses the pinned known-good linux-next commit from `config/build.env`; enter `master` explicitly only when testing a newer tree. Download the `zenbook-a16-linux-next-N` artifact from the run; it includes a `.sha256` checksum. The bundle's `metadata/` directory records the exact `.config`, Fedora config source and digest, linux-next commit, kernel release, A16 DTB and checksum, configuration audit, and Qualcomm/all-module inventories.

`config/a16-required.config` is the reviewed A16 early-boot set. `scripts/build.sh` applies it after importing and normalizing Fedora Rawhide's AArch64 config, runs `olddefconfig` again, and then calls `scripts/audit-config.sh`. Update this list deliberately when upstream renames or removes a symbol; do not weaken the audit just to make CI green.

`config/build-overrides.config` removes only large build-time debug, sanitizer, BTF, GDB, and module-signing payloads that are not needed for boot diagnostics. The workflow also reclaims unused hosted-runner SDKs and persists a 5 GB `ccache`, including after failed builds, so unchanged translation units are reused on retries. GitHub-hosted runners themselves are ephemeral, so a run completed before this cache was added cannot be resumed.

There are three workflows:

- **Nightly ASUS Zenbook A16 kernel** builds (or restores) the kernel bundle only.
- **Build Ubuntu ARM64 A16 live USB image** quickly creates an image from an existing
  successful kernel run. Leave its run ID blank to use the newest successful one.
- **Full build - kernel and Ubuntu ARM64 A16 live USB image** performs the full kernel and GUI
  image sequence in one run. Use this longer workflow when an overnight rebuild
  is needed; the GUI stage uses the exact kernel artifact produced by its first stage.

For a local Ubuntu/Debian build:

```bash
sudo apt update
sudo apt install -y git bc bison flex libssl-dev libelf-dev \
  gcc-aarch64-linux-gnu device-tree-compiler zstd pipx
pipx install b4
git clone https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git
git clone <your-fork-url> a16-nightly
cd a16-nightly
bash scripts/apply-series.sh ../linux-next
bash scripts/build.sh ../linux-next
bash scripts/package.sh ../linux-next
```

### WSL2 launcher

For a repeatable local kernel and GUI-image build under Ubuntu/Debian WSL2, use
the repository launcher. Keep both the checkout and its work directory in the
WSL Linux filesystem (for example, under `~/src`), rather than `/mnt/c`, for
substantially better filesystem performance during kernel compilation.

```bash
git clone https://github.com/jc372/A16Build.git ~/src/A16Build
cd ~/src/A16Build
chmod +x scripts/run-wsl-build.sh
./scripts/run-wsl-build.sh both --work-dir ~/a16-work --jobs "$(nproc)"
```

The launcher supports `kernel`, `gui`, `both`, and `ubuntu-baseline` modes. It detects the host
from `/etc/os-release`: Fedora builds retain the Fedora Rawhide Xfce raw-image
path, while Ubuntu and Debian build from the current official Ubuntu ARM64
desktop daily-live ISO. It installs the host-specific packages needed by the
selected build, reuses a local ccache, and writes outputs to `<work-dir>/out`.
Before downloading or building, it verifies the external tools needed for the
selected mode and reports every missing command together.

Before changing the Ubuntu kernel again, reproduce the known-booting Ubuntu
daily image (default series: `resolute`, 26.04 LTS) unchanged:

```bash
./scripts/run-wsl-build.sh ubuntu-baseline
```

This mode does not build linux-next and does not remaster the ISO. It verifies
Canonical's published checksum, creates a byte-for-byte identical output, and
then independently compares `/casper/vmlinuz`, `/casper/initrd`, and
`/boot/grub/grub.cfg`. The output report records all hashes and sizes. Use this
artifact to confirm the baseline before applying A16 kernel changes.
Each local `kernel` or `both` run resets the private `linux-next` worktree and
removes its kernel object output before applying the A16 series, while keeping
the compiler cache and packaged outputs for speed.
On Fedora, local GUI builds intentionally leave the finished image as an
uncompressed `.raw` file. The default uses the pinned Fedora Xfce Rawhide image
associated with the known-good kernel baseline; `--latest` discovers the newest
Rawhide image. On Ubuntu/Debian, the launcher verifies and reuses the current
Ubuntu ARM64 daily ISO and produces a bootable `.iso`. Both base images and the
large Qualcomm firmware RPM are cached under `local-wsl-build/downloads` and
are downloaded again only when the selected image or firmware RPM changes.
Local output retention keeps the two newest generated images or kernel bundles
by default; override it with `--keep-output N`. Pass `--split-size 1900m` to
split the final artifact. Neither path writes a physical disk, changes
UEFI/NVRAM, or touches Windows EFI.

## USB boot testing (do not overwrite Windows EFI)

Use a separate, non-default USB boot path. Keep the internal Windows drive and its EFI System Partition untouched.

1. Use a Linux ARM64 USB image whose bootloader can load a custom kernel (for example, an ARM64 Fedora/Arch test image prepared for this device).
2. Back up the USB's `EFI` directory. Copy `Image`, the matching DTB(s), and `modules/` from the artifact **to the USB only**, following that distro's bootloader layout and configuration.
3. Install the modules into the USB root filesystem, retaining the kernel-release directory structure from the archive.
4. Select the USB entry from the firmware's one-time boot menu. Do not change default boot order and do not run `efibootmgr` against the internal disk.
5. Keep a known-good USB and the original Windows boot option available. If it fails, power off, remove the USB, and boot Windows normally.

Exact DTB and bootloader filenames can change while the A16 support is upstreaming; inspect `dtbs/` in the artifact and the target distro's existing ARM64 boot entries instead of guessing. Secure Boot may reject an unsigned development `Image`; do not disable or modify Windows boot protection solely for this test.

## Disposable Fedora GUI USB image

On a Fedora host, `scripts/run-wsl-build.sh gui` creates a complete ARM64 Fedora Rawhide Xfce disk image while retaining Fedora userspace, filesystem, and GRUB tooling. Its finished boot image contains only the custom A16 kernel release: Fedora kernel files, initramfs images, module trees, and BLS kernel entries are removed. The builder generates a fresh generic dracut initramfs for that custom release, including the matching module tree, root-storage drivers, and the newest Rawhide Qualcomm firmware. Every A16 entry deliberately boots to a text console until early platform and display bring-up are stable.

The image provides three A16 GRUB profiles. All remove `rhgb`, `quiet`,
`splash`, and `nomodeset`, disable Plymouth and the display manager, boot to
`multi-user.target` (a text console), retain `rootwait`, force the visible `tty0` console, and allow deferred hardware suppliers up to 60 seconds to settle:

- **text console** uses the custom kernel without verbose diagnostics or a
  window manager;
- **debug logging** adds `loglevel=7`, `ignore_loglevel`, `initcall_debug`,
  visible systemd status;
- **firmware framebuffer, MSM DRM disabled** adds the debug options and blocks
  both the built-in MSM DRM registration initcall and the modular `msm` driver,
  preserving the early framebuffer for display-handoff diagnosis. This profile
  therefore also works with the already-built kernel where MSM DRM is built in.

Choose or edit these options directly in GRUB; changing them only requires an
image rebuild, not a kernel compile. There is no stock Fedora-kernel entry in
the finished image.

GUI-only mode reuses the newest local kernel bundle and does not compile the kernel again.

Download its `.raw.xz.00.part`, `.01.part` (and any later parts), plus the checksum. Reassemble and verify it, then write it to a dedicated USB drive (16 GB or larger) from another machine:

```bash
cat fedora-xfce-a16-*.raw.xz.*.part > fedora-xfce-a16.raw.xz
sha256sum -c fedora-xfce-a16-*.raw.xz.sha256
xz -d -c fedora-xfce-a16.raw.xz | sudo dd of=/dev/sdX bs=16M conv=fsync status=progress
```

`/dev/sdX` must be the whole removable USB drive—not a partition and never the internal Windows disk. Boot it through the firmware’s one-time boot menu, then select the desired **Fedora Xfce - ASUS Zenbook A16** profile in GRUB. There is no stock Fedora-kernel entry in the finished image; recovery remains the untouched Windows boot option or a separate known-good USB. The script does not touch NVRAM, default boot order, Windows EFI, or the internal disk.

## Ubuntu ARM64 daily-live image

The default series is the Ubuntu 26.04 LTS daily (`resolute`), whose installer
is the current install target; the previously verified live-session baseline
(`stonking`) remains selectable. Choose the series per build with
`--ubuntu-series <name>` (for example `--ubuntu-series stonking`), or change
`UBUNTU_DAILY_SERIES` in `config/build.env` as the default. Run
`scripts/run-wsl-build.sh ubuntu-baseline` first; the custom-kernel `gui` and
`both` paths described below are intentionally separate experiments.

Ubuntu and Debian hosts use the current official Ubuntu ARM64 desktop daily
ISO for the configured series (default `resolute`, 26.04 LTS) as the
known-booting userspace, graphical live environment, and installer. The
builder preserves Ubuntu's signed ARM64 EFI/GRUB boot structure, replaces
`/casper/vmlinuz` with the pinned custom A16 `Image`, adds the matching Glymur
DTB, and rebuilds `/casper/initrd` with exactly the matching custom module tree
and the cached current Qualcomm firmware. An initramfs local-bottom handoff
copies those modules and firmware into Casper's writable live-root overlay, so
they remain available after `switch_root`.

The generated GRUB menu provides four A/B test profiles using the same custom
kernel. Every title includes the exact `ASUS Zenbook A16 build <kernel-release>`
identifier. The default **DTB diagnostic console** entry removes `quiet` and
`splash`, suppresses built-in MSM DRM, keeps firmware console output, prevents
automatic panic reboot, and boots `multi-user.target`. **DTB graphics** enables
the normal display stack. Matching **ACPI diagnostic** and **ACPI graphics**
entries test Ubuntu's hardware-description path without forcing a DTB. This
makes the boot path selectable without another image rebuild and ensures the
diagnostic entries cannot silently inherit Ubuntu's stock quiet command line.
The image builder also rejects an older kernel bundle that lacks the audited
EFI/simple-framebuffer console configuration; run `both` rather than `gui`
after pulling a change to `config/a16-required.config`.

The live session uses only the custom A16 kernel release. The Ubuntu installer
is preserved, but it may install Ubuntu's packaged kernel into the permanent
target; custom-kernel installation into the target is deliberately not claimed
yet.

Write the ISO directly to a dedicated USB drive, or reassemble split parts first:

```bash
cat ubuntu-desktop-a16-*.iso.*.part > ubuntu-desktop-a16-<kernel-release>.iso
sha256sum -c ubuntu-desktop-a16-*.iso.sha256
sudo dd if=ubuntu-desktop-a16.iso of=/dev/sdX bs=16M conv=fsync status=progress
```

## Safety and status

Hardware support is evolving. Expect regressions, and treat this as a disposable test environment. The workflow deliberately never creates an EFI boot entry, writes firmware variables, flashes firmware, or packages a disk image.
