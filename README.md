# Nightly ASUS Zenbook A16 (UX3607OA) Linux kernels

This repository builds an **ARM64 development kernel** from `linux-next`, then applies the Qualcomm ASUS Zenbook A16 / Snapdragon X2 (Glymur) patch series and only explicitly listed missing prerequisites. It starts with Fedora Rawhide's current AArch64 kernel configuration, forces the early-boot Glymur supplier and peripheral drivers built in, and fails the build if any required option is lost. It publishes an `Image`, DTBs, modules, and build diagnostics in a compressed GitHub Actions artifact.

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

The workflow runs nightly at 03:23 UTC and supports **Run workflow** for an on-demand build. Fork this repository, enable Actions, and run the workflow. Download the `zenbook-a16-linux-next-N` artifact from the run; it includes a `.sha256` checksum. The bundle's `metadata/` directory records the exact `.config`, Fedora config source and digest, linux-next commit, kernel release, A16 DTB and checksum, configuration audit, and Qualcomm/all-module inventories.

`config/a16-required.config` is the reviewed A16 early-boot set. `scripts/build.sh` applies it after importing and normalizing Fedora Rawhide's AArch64 config, runs `olddefconfig` again, and then calls `scripts/audit-config.sh`. Update this list deliberately when upstream renames or removes a symbol; do not weaken the audit just to make CI green.

`config/build-overrides.config` removes only large build-time debug, sanitizer, BTF, GDB, and module-signing payloads that are not needed for boot diagnostics. The workflow also reclaims unused hosted-runner SDKs and persists a 5 GB `ccache`, including after failed builds, so unchanged translation units are reused on retries. GitHub-hosted runners themselves are ephemeral, so a run completed before this cache was added cannot be resumed.

There are two workflows:

- **Nightly ASUS Zenbook A16 kernel** builds (or restores) the kernel bundle only.
- **Build Fedora Xfce GUI USB image** automatically runs the kernel workflow first
  and uses that exact bundle. Supplying a successful kernel run ID skips the new
  kernel build and reuses the requested bundle instead.

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

The **Build Fedora Xfce GUI USB image** workflow creates a complete ARM64 Fedora Rawhide Xfce disk image with the custom A16 kernel as an additional, non-default boot entry. Xfce is deliberately used as a compact GUI for early bring-up. The image overlays the newest Rawhide `qcom-firmware` package, makes that firmware available in the A16 initramfs, installs module dependency metadata, and stores the kernel build metadata under `/usr/share/a16-build/`.

The A16 entry is permanently configured for visible bring-up diagnostics. It removes `rhgb`, `quiet`, `splash`, and `nomodeset`, disables Plymouth, and adds:

```text
rd.plymouth=0 plymouth.enable=0 plymouth.use-simpledrm=0 loglevel=7 ignore_loglevel initcall_debug deferred_probe_timeout=30 systemd.show_status=1 rd.systemd.show_status=1 rootwait
```

These options expose kernel and systemd progress while preserving Qualcomm DRM initialization. The stock Fedora entry remains unchanged for comparison.

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
