# Nightly ASUS Zenbook A16 (UX3607OA) Linux kernels

This repository builds an **ARM64 development kernel** from `linux-next`, then applies the Qualcomm ASUS Zenbook A16 / Snapdragon X2 (Glymur) patch series and only explicitly listed missing prerequisites. It publishes an `Image`, DTBs, and modules in a compressed GitHub Actions artifact.

It is designed for testing upstream enablement. It is not an installer, not a recovery image, and not a replacement for the Windows boot chain.

## Configure the patch stack

`config/series.env` holds the A16 mailing-list Message-ID. Update it whenever an updated series is posted. Prerequisites belong in `DEPENDENCY_SERIES_MSGIDS` **only after confirming they are absent from the current linux-next tree**. Keep the list empty otherwise.

`A16_PATCH_SELECTION` records the numbered patches that are still missing from the configured A16 series. It is set to `3` because linux-next has already integrated the binding and board-DTS patches from the current series. Set it empty for a new, wholly missing series, or update it after checking the latest linux-next integration.

`scripts/apply-series.sh` downloads each series with `b4`, splits it into individual patches, and checks every patch before applying it:

- applies a clean patch with `git am --3way`;
- skips a patch whose reverse applies cleanly (it is already present);
- stops if a patch is neither clean nor already present.

It never uses `git am --skip`, `--ignore-space-change`, or force application. That makes reruns safe and exposes genuine dependency conflicts.

## GitHub Actions

The workflow runs nightly at 03:23 UTC and supports **Run workflow** for an on-demand build. Fork this repository, enable Actions, and run the workflow. Download the `zenbook-a16-linux-next-N` artifact from the run; it includes a `.sha256` checksum.

There are two deliberately separate workflows:

- **Nightly ASUS Zenbook A16 kernel** builds (or restores) the kernel bundle only.
- **Build Fedora Xfce GUI USB image** consumes a successful kernel bundle and creates the disposable GUI USB image; it never recompiles the kernel.

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

## USB boot testing (do not overwrite Windows EFI)

Use a separate, non-default USB boot path. Keep the internal Windows drive and its EFI System Partition untouched.

1. Use a Linux ARM64 USB image whose bootloader can load a custom kernel (for example, an ARM64 Fedora/Arch test image prepared for this device).
2. Back up the USB's `EFI` directory. Copy `Image`, the matching DTB(s), and `modules/` from the artifact **to the USB only**, following that distro's bootloader layout and configuration.
3. Install the modules into the USB root filesystem, retaining the kernel-release directory structure from the archive.
4. Select the USB entry from the firmware's one-time boot menu. Do not change default boot order and do not run `efibootmgr` against the internal disk.
5. Keep a known-good USB and the original Windows boot option available. If it fails, power off, remove the USB, and boot Windows normally.

Exact DTB and bootloader filenames can change while the A16 support is upstreaming; inspect `dtbs/` in the artifact and the target distro's existing ARM64 boot entries instead of guessing. Secure Boot may reject an unsigned development `Image`; do not disable or modify Windows boot protection solely for this test.

## Disposable Fedora GUI USB image

The **Build Fedora Xfce GUI USB image** workflow creates a complete ARM64 Fedora Rawhide Xfce disk image with the custom A16 kernel as an additional, non-default boot entry. Xfce is deliberately used as a compact GUI for early bring-up.

It reuses the newest successful nightly kernel artifact (or a run ID you supply) and does not compile the kernel again. The nightly workflow also caches an unchanged bundle by linux-next revision and build-script configuration.

Download its `.raw.xz.00.part`, `.01.part` (and any later parts), plus the checksum. Reassemble and verify it, then write it to a dedicated USB drive (16 GB or larger) from another machine:

```bash
cat fedora-xfce-a16-*.raw.xz.*.part > fedora-xfce-a16.raw.xz
sha256sum -c fedora-xfce-a16-*.raw.xz.sha256
xz -d -c fedora-xfce-a16.raw.xz | sudo dd of=/dev/sdX bs=16M conv=fsync status=progress
```

`/dev/sdX` must be the whole removable USB drive—not a partition and never the internal Windows disk. Boot it through the firmware’s one-time boot menu, then select **Fedora Xfce - ASUS Zenbook A16 test kernel** in GRUB. The stock Fedora entry remains available as a fallback. The script does not touch NVRAM, default boot order, Windows EFI, or the internal disk.

## Safety and status

Hardware support is evolving. Expect regressions, and treat this as a disposable test environment. The workflow deliberately never creates an EFI boot entry, writes firmware variables, flashes firmware, or packages a disk image.
