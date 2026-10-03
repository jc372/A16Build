# Phase 1 — WSL: build the kernel payload and remaster the installer

The stock daily's kernel does not drive this machine, so the installer media is rebuilt around a
linux-next kernel built with this machine's configuration. Both halves run in WSL and need no
hardware.

## 1.1 Why the media is remastered rather than used as-is

- The stock kernel has no support for the display path, and the live session needs a console.
- The A16 device tree has to be in the image, because the DT path (with `acpi=off`) is what makes
  internal input work.
- The Fedora Rawhide `qcom-firmware` and `atheros-firmware` packages are current; the ones in the
  daily are older than this machine's devices.

## 1.2 Build the kernel payload

    scripts/run-wsl-build.sh kernel                     # fetch linux-next, build, package
    scripts/run-wsl-build.sh kernel --ref next-20260914 # or pin a daily tag / SHA

The A16 series (binding, board DTS, QSEECOM firmware allowlist) is upstream in linux-next since
2026-08-14, so nothing needs applying by hand; `scripts/apply-series.sh` and `config/series.env`
exist for the case where you do want to apply a mailing-list series (`b4` is what fetches them).

The build uses the configuration in `config/`:

    config/ubuntu-generic-arm64.config   base configuration
    config/a16-required.config           the options this machine needs
    config/build-overrides.config        build overrides
    config/build.env                     upstream input URLs
    config/series.env                    mailing-list message IDs (empty = nothing applied)

Output: `zenbook-a16-<version>.tar.zst` — kernel, initrd, device trees, modules, and `metadata/`
with the config and the exact commit. That bundle is the input to the remaster and to the first
boot.

## 1.3 Remaster the installer image

    scripts/make-ubuntu-desktop-usb-iso.sh \
        <path>/zenbook-a16-<version>.tar.zst \
        <ubuntu-daily-desktop-arm64.iso-url>

What it does, in order:

1. downloads the daily (resumable) and verifies it if you gave it a hash;
2. unpacks the bundle, requires the A16 device tree inside it
   (`dtbs/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb`), and reads `CONFIG_ARM64_VA_BITS` from the
   bundle's kernel config;
3. downloads the newest `qcom-firmware` and `atheros-firmware` RPMs from Fedora Rawhide and unpacks
   them into the ISO's firmware payload;
4. writes the bundle's kernel, initrd and device tree into `/casper`;
5. writes a GRUB menu whose entries include diagnostics:
   `acpi=off console=tty0 earlycon keep_bootcon loglevel=8 initcall_debug ... module_blacklist=msm`;
6. installs a `casper-bottom` hook (`65a16-live-root`) into the initrd — it runs inside the live
   session and is where extra live-session behaviour is attached.

Useful knobs (environment variables, all optional):

    VARIANT_SUFFIX=-h1        label the build, so variants are not confused when flashing
    DEFAULT_MENU_ENTRY=0      which entry the menu preselects
    STOCK_ENTRIES=1           keep the daily's own entries alongside the A16 ones
    DIAGNOSTIC_CONSOLE=earlycon=efifb
    DTB_OVERRIDE=<file>       use a different device tree for this image
    OUT=..., DOWNLOAD_DIR=..., TMPDIR=...

Verify the hook is really in the initrd before flashing — a hook in the wrong initramfs phase is
never run, silently:

    xorriso -indev <iso> -osirrox on -extract /casper/initrd /tmp/i \
      && gzip -dc /tmp/i | cpio -i --to-stdout scripts/casper-bottom/ORDER | grep 65a16-live-root

## 1.4 Flash it

**Secure Boot off** before booting the media (standing rule: off for Linux, on for Windows — README).

The image goes on a **USB stick** or the machine's **SD card** — both are fine. Whichever you use,
keep the USB-A port free for the dock (keyboard, mouse, Ethernet): a USB-C device will not be seen
during the install.

Rufus 4.14, **DD image mode**, **Secure Boot off**. Keep the Rufus log.

## 1.5 Check before you boot

    ls -l <out>/  # the remastered ISO, and its checksum sidecar if produced
    # and on the machine: Esc at power-on -> boot options -> the stick appears
