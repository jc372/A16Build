# A16 bring-up — everything done on 2026-09-16, and how to do it again

> Boot entries [2] and [3]: what actually differs — see `docs/boot-options.md`.

This directory is the reproducible record of the **second half** of the A16 project: from the
moment the machine booted a Linux install of its own and could be worked on *in place*
(2026-09-16, ~11:00 EDT) through Bluetooth coming up (~16:35 EDT) — Wi-Fi, firmware, the
device-tree boot path, audio measurement and the whole Bluetooth chain.

It answers three questions:

1. **What did we do, and why?** → this file, section by section, with the evidence each step
   produced.
2. **How does someone (or a future agent) get here again from a fresh install?** → `steps/`
   (the ordered pipeline), `tools/` (the implementations), `patches/` (the diffs).
3. **What is left?** → `NEXT-STEPS.md`.

Everything before this window — building live ISOs on WSL, flashing sticks, harvesting from the
live session, the ESP staging/repair work — is **archived, not deleted**, in
`../archive/2026-09-16-pre-bringup/`. Read that directory's README if you need the earlier era.

---

## 0. The machine, in facts

| | |
|---|---|
| Model | ASUS Zenbook A16 (`UX3607OA`), BIOS `UX3607OA.312 07/12/2026` |
| SoC | Snapdragon X2 Elite "Glymur" (SoC id 8480), arm64 |
| RAM | 48 GiB; DT boot sees 47.6 GiB (`MemTotal: 47626788 kB`) |
| Internal disk | Samsung `MZVL81T0HFLB-00BTW` |
| Linux root | `/dev/nvme0n1p17`, UUID `f8e005e9-414c-4c8e-ad68-d1e9fdc208bc` |
| ESP | the FAT partition holding `EFI/` + this project's `a16boot/` (82 MB of payload) |
| Windows | partition 12, still the first entry in the firmware boot order |
| WLAN/BT part | Qualcomm **FastConnect C7700 / NCM820A** — WLAN is `PCI 17cb:1112` (bound by `ath12k`, which calls it QCC2072); **BT is a UART device on `uart14`** (`a98000.serial`, DT alias `serial1`) |
| Module power | `VREG_WCN_3P3` — a GPIO-94-switched fixed regulator in the machine DTB, `regulator-boot-on` |
| Module kill lines | M.2-style: `w-disable1` = TLMM GPIO **117** (WLAN), `w-disable2` = TLMM GPIO **116** (Bluetooth), both active-low in the DTB |
| Network while working | USB-C dock Ethernet (`enp…`) + Wi-Fi once step 40 landed |

The vendor firmware used by Linux was extracted from the machine's own Windows install and is
committed at `../firmware/windows-driverstore-2026-09-16/` (326 files, 87 MiB, `sha256sum -c`
clean), with the device→driver→package inventory in `host-inventory/`.

### The starting state (before this window)

Ubuntu 26.10 daily installed on the internal disk, booting in **ACPI mode**. It worked, but:
no internal keyboard/touchpad (the firmware's I2C controllers are `ACPI\QCOM0F10`, which
`i2c-qcom-geni` does not match, so the I2C-HID children never enumerate), no Wi-Fi, no sound, no
Bluetooth. The session was driven over the dock's Ethernet and an external keyboard.

### Where it stands now (verified, this boot)

| Subsystem | State | Evidence |
|---|---|---|
| Panel | picture, from the firmware framebuffer (`simpledrmdrmfb`, one fixed 2880x1800 mode); **no backlight device** (so no brightness control) and no modesetting (so no refresh-rate options) | `card0-Unknown-1 = connected`, `/sys/class/backlight` empty, `msm` blacklisted — NEXT-STEPS item 7 |
| Internal input | **works** — keyboard, touchpad, touchscreen, lid | 9 internal i2c-HID devices, `Asus Keyboard`, `hid-over-i2c 093A:3012 Touchpad` |
| Wi-Fi | **works** | `wlP4p1s0` up, associated to `hn` @ 5745 MHz, −58 dBm |
| Bluetooth | **works** | `hci0` = `3C:EF:A5:29:6A:62`, `Powered: yes`, `Discoverable: yes`; audio streams over a BT speaker |
| DSPs / audio | card + 4 WSA884x amps up, **no sound to the internal speakers** (needs a machine ACPI topology) | `notes/2026-09-16-hermes-audio-state.md` |
| Battery gauge | **works** — 81.8 % (upower, computed from `energy_*`), 66.6 Wh of 70.0 Wh design (95 % health), 42 cycles, 30 °C; ASUS conservation mode visible as `charge_control_start/end_threshold = 75/80` | `upower -i …/battery_qcom_battmgr_bat`. Note: this driver variant (X1E80100 property set) exports **no `capacity` attribute**, which is why a raw `cat capacity` reads empty |
| Suspend | untested; `mem_sleep` defaults to `deep` (`s2idle [deep]`) | `NEXT-STEPS.md` item 5 |

---

## 1. The story, step by step

Each step below has a matching script in `tools/` and a wrapper in `steps/`. The wrappers check
prerequisites, call the tool, and state what the outcome must look like.

### 10 — A kernel and a device tree that describe this machine

**Why:** the distro kernel is an ACPI-mode kernel. The internal input devices only exist in the
*devicetree* description, and the machine's own DTB (shipped in the vendor package) is the one
that carries the memory map and carveouts. Upstream's A16 DTS cannot be used as a drop-in
because it has no `/memory` node — Qualcomm platforms expect the *firmware's* DT in the UEFI
configuration table with the Linux DTB applied on top, and GRUB's `devicetree` command *replaces*
that tree, which is why the first DTB attempts died with no console at all.

**What:** `tools/a16-install-next-kernel.sh` unpacks the pinned linux-next bundle
(`zenbook-a16-7.3.0-rc3-next-20260914.tar.zst`, 195,503,048 B, sha256 `2cb362c2…` — the export
payload, not in this repo) and installs: `/boot/vmlinuz-7.3.0-rc3-next-20260914`, an initramfs
built for it (nvme is a module, so one is required), `/lib/modules/7.3.0-rc3-next-20260914`
(~680 MB), `/boot/glymur-asus-zenbook-a16-ux3607oa.dtb`, and the **9-entry GRUB menu** written to
four config copies on the ESP (`a16boot/grub.cfg`, `EFI/Boot/grub.cfg`, `EFI/ubuntu/grub.cfg`,
`EFI/ubuntu_snapdragon/grub.cfg`).

The menu (30 s timeout, `default=1`) is the boot control panel for everything after:

```
[0] installed Ubuntu 7.2 staged on the ESP (ACPI) — picture, no internal input
[1] 7.2 + glymur DTB, internal input, panel via firmware framebuffer   <- 7.2 kernel staged on the ESP
[2] next 7.3 + glymur DTB, panel left to firmware (msm/display CCs blacklisted)   <- what this machine boots
[3] next 7.3 + glymur DTB, full display attempt (msm + panel enabled)
[4] next 7.3 + DTB, msm enabled but panel PHY left unmanaged
[5] installed Ubuntu — its own generated grub.cfg (normal path)
[6] diagnostics — photograph this screen
[7] Windows Boot Manager
[8] 7.3 + glymur DTB + Bluetooth serdev test (added in step 50)
```

**Which entry is which — read this before asking someone to "go back to the working one".**
The titles are stale and the command lines overlap, so the distinguishing facts are the *kernel
path* and the *flags*:

| Entry | Kernel it loads | DTB it loads | Display flags |
|---|---|---|---|
| [0] | `/a16boot/vmlinuz` (ESP, staged 7.2) | **none** (ACPI) | ACPI |
| [1] | `/a16boot/vmlinuz` (ESP, staged 7.2) | `/a16boot/glymur-…dtb` (ESP copy) | `msm` + display CCs blacklisted |
| **[2]** | `/boot/vmlinuz-7.3.0-rc3-next-20260914` | `/boot/glymur-…dtb` (rootfs copy) | `msm` + display CCs blacklisted ← **the working entry, and what the machine normally boots** |
| [3] | `/boot/vmlinuz-7.3.0-rc3-next-20260914` | `/boot/glymur-…dtb` | none — msm **and** panel enabled (the display attempt) |
| [4] | `/boot/vmlinuz-7.3.0-rc3-next-20260914` | `/boot/glymur-…dtb` | only `phy_qcom_edp` blacklisted (safe probe) |
| [5] | distro 7.2 from the rootfs, its own config | — | ACPI |
| [8] | `/boot/vmlinuz-7.3.0-rc3-next-20260914` | `/boot/glymur-a16-bt-test.dtb` | same blacklists as [2] |

Two consequences worth knowing: `BOOT_IMAGE=` in `/proc/cmdline` separates [2]/[3]/[4]/[8] from
[0]/[1]/[5] (ESP kernel vs rootfs kernel) but *not* those four from each other; and since arming
installed the BT test DTB over the stock paths, **[2], [3], [4] and [8] all load the same bytes**
(sha256 `d8fe1c62…`) — so [8] is [2] with a different file name, and [2] is the entry to return to.

**Evidence:** `/boot/efi/A16NEXTKERNEL.LOG`, `/boot/efi/A16DTBOOT.LOG`, the boot reports under
`/boot/efi/a16-reports/`.

### 20 — Boot it on the device tree (the entry that made the machine drivable)

**Why:** ACPI mode cannot reach the keyboard or touchpad on this platform at all
(`QCOM0F10`/`QCOM0F0C` are unmatched by `i2c-qcom-geni` and the pinctrl driver). The DT path can,
and it did.

**What:** `tools/a16-stage-dt-boot.sh` puts the machine DTB on the ESP and writes the DT entries.
The kernel command line on those entries is not decoration:

```
acpi=off                              arm64 prefers ACPI whenever tables exist
clk_ignore_unused pd_ignore_unused regulator_ignore_unused
                                      without these the kernel takes the panel down: msm claims
                                      fb0 after a panel-probe failure, then the regulator late
                                      cleanup cuts VREG_EDP_3P3
module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20
                                      keep the display pipeline out of the way (entry [1]/[2])
console=tty0 keep_bootcon loglevel=7  a failure has to be readable on the panel
```

**Verify:** `tools/a16-dt-verify.sh` — internal input devices, i2c adapters, panel state; plus
the per-boot report (`tools/a16-boot-report.sh`, installed as a systemd oneshot by
`tools/a16-enable-boot-report.sh`) which writes a full report set to `/boot/efi/a16-reports/`.

### 30 — Firmware: DSPs, Bluetooth blobs, provenance

**What:**
- `tools/extract-windows-a16-firmware.sh` — the extraction that produced the committed
  `firmware/windows-driverstore-2026-09-16/` tree (how the *inputs* got here at all).
- `tools/a16-install-firmware.sh` — installs the four DSP blobs the payload carries into
  `/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/` (`qcadsp8480.mbn`, `qccdsp8480.mbn`,
  `adsp_dtbs.elf`, `cdsp_dtbs.elf`) and brings the ADSP/CDSP up live.
- `tools/a16-fix-dsp.sh`, `tools/a16-install-tplg.sh` — the DSP/audio-topology attempts.
- `tools/a16-bt-setup.sh install` — installs the Bluetooth files under `/lib/firmware/qca/`:
  `hmtbtfw20.tlv` + `.ver`, `hmtnv20.b105/b10f/b112/b3b`, `clnbtfw10.tlv`, `clnbtnv10.b03/b17`,
  `bsrc_bt.bin`. Verified against the repo manifest before installing.

### 40 — Wi-Fi: this machine's own board data

**Why:** `ath12k` bound the QCC2072 and loaded its firmware, but every attempt failed with
`failed to fetch board data`: the shipped `board-2.bin` has no entry for this machine's BDF
key. The fix was to wrap the machine's *own* vendor board-data image under the right key rather
than to find a matching upstream blob.

**What:** `tools/make-a16-qcc2072-board-2.sh` (with `tools/ath12k-bdencoder` and
`tools/ath12k-bdf-from-elf.py`) builds `board-2.bin` (526,972 B, sha256 `314e2d57…`) for
`subsystem-device=e14f, qmi-chip-id=33, qmi-board-id=255[,variant=UX3407Q]`, wrapping
`bdwlan_qcc2072_1p0_ncm820A.elf`. Committed at `../firmware/ath12k-board-2-qcc2072-e14f/` with
the pristine distro container and a README. `tools/a16-wifi-bdf-test.sh` installs candidates and
verifies (it has `--dry-run` and `--verify`); `tools/a16-wifi-tune.sh` is the profile tuning.

**Result:** 0 `failed to fetch board data` lines, `wlP4p1s0` up, scans and associates. Verified
again in this window: associated to `hn` at 5745 MHz, −58 dBm.

### 50 — Bluetooth: three layers deep, and the one that mattered

This is the longest chain of the day; it is worth reading in order, because each layer's
"failure" is a fact that ships in the next layer's fix.

**50a — the transport has no tty, by design.**
`a16bt` — `uart14` (`a98000.serial`) is registered as a **serdev controller** (its port device
carries a `serial0` child), so the kernel hides the tty on purpose: all eight `qcom_geni_uart`
minors return `ENXIO`, and `btattach` can never open it. A serdev *client* is what binds
`hci_uart` / `hci_qca`, and the DT had none. `tools/a16-bt-setup.sh status` proves this and
identifies the live DTB by decompiling `/proc/device-tree` and looking for
`compatible = "qcom,wcn7850-bt"` — cmdline cannot tell the DT entries apart, they are identical.

**50b — a patched DTB that gives uart14 its client.**
`tools/a16-bt-dtb.sh` decompiles the **stock** DTB, inserts under `serial@a98000`:

```dts
bluetooth {
        compatible = "qcom,wcn7850-bt";
        max-speed = <3200000>;
        vddio-supply = <&a16_bt_vddio>;      /* …and five more */
};
```

plus six always-on `regulator-fixed` stubs (`vddio`, `vddaon`, `vdddig`, `vddrfa0p8`,
`vddrfa1p2`, `vddrfa1p9`) because `hci_qca`'s WCN7850 data calls
`devm_regulator_bulk_get()` for all six and the A16 DTS describes none of them. The driver side
was checked on disk rather than assumed: `hci_uart.ko` carries
`alias: of:N*T*Cqcom,wcn7850-bt`, `CONFIG_BT_HCIUART_QCA=y` (hci_qca lives *inside* `hci_uart`),
`btqca.ko` is installed.

**50c — getting that DTB in front of a boot without relying on the menu.**
`tools/a16-bt-arm.sh`: entries [1]–[4] read the stock DTB from two fixed paths
(`/boot/glymur-asus-zenbook-a16-ux3607oa.dtb` and its ESP twin). The script backs both up to
`<path>.a16stock` (once, never overwritten) and installs the patched DTB over them, so whichever
DT entry the machine takes, it boots the patched description. `revert` restores and both
directions abort unless the file matches the sha they expect. This exists because two reboots
landed on the *default* entry, not [8] — and with identical cmdlines, the live DT was the only
evidence of which row had run.

**50d — the chip was mute: `0xfc00 tx timeout`, `-110`, three retries.**
The serdev bind worked (device `serial0-0` bound to `hci_uart_qca`), `hci0` was created, the
driver logged `setting up wcn7850` — and then every ROM-version read timed out. `hci0` existing
is *not* success: it is created by the bind whether or not power-on works.

**50e — the wrong hypothesis, and why it was worth one run.**
`tools/a16-bt-enable.sh` tested "the module's BT kill line is held asserted" from userspace. It
cannot work: the line is already owned by a driver (the sysfs export returns `EBUSY`). It is kept
as the probe for those lines and is marked superseded.

**50f — the actual cause, read out of the driver source.**
The machine DTB's `wlan-connector` node (`compatible = "pcie-m2-e-connector"`) is bound by
`pwrseq-pcie-m2`, which requests the two kill lines:

```c
w_disable1_gpio = devm_gpiod_get_optional(dev, "w-disable1", GPIOD_OUT_HIGH);
w_disable2_gpio = devm_gpiod_get_optional(dev, "w-disable2", GPIOD_OUT_HIGH);
uart_enable():  gpiod_set_value_cansleep(ctx->w_disable2_gpio, 0);   /* Bluetooth target */
pcie_enable():  gpiod_set_value_cansleep(ctx->w_disable1_gpio, 0);   /* WLAN target      */
```

`w_disable2` is the UART/Bluetooth target. Both properties are `GPIO_ACTIVE_LOW`, so
`GPIOD_OUT_HIGH` **at probe time** is a *logical* 1 = **physical LOW** = the kill line asserted:
the BT core is held off from the moment the driver probes. The driver deasserts it only inside
its `uart-enable` unit, which runs for the serdev BT device it creates *itself* — and it creates
those only for PCI IDs in its table (`17cb:1103`, `17cb:1107`). This machine is `17cb:1112`, so
no consumer ever enables that unit. WLAN is unaffected because the PCIe target *does* have a
consumer (the PCI device, via `pci-pwrctrl-pwrseq`) — which is exactly why Wi-Fi came up and
Bluetooth never did.

**50g — the fix, and it is one cell.** `tools/a16-bt-dtb.sh` now also rewrites
`w-disable2-gpios`'s flags cell from `0x1` (ACTIVE_LOW) to `0x0` (ACTIVE_HIGH), so the driver's
initial output is a physical HIGH — the level Windows leaves the line at. It refuses to build if
the property is missing or the flags are not what it expects, writes a sha256 sidecar beside the
artifact (which `a16-bt-arm.sh` then reads, so a pinned sha cannot lag a rebuild), and with
`--install` runs the arm step itself so the whole thing is one command.

**Result — the chip answers:**

```
Bluetooth: hci0: QCA Product ID   :0x00000020
Bluetooth: hci0: QCA SOC Version  :0x40292100
Bluetooth: hci0: QCA ROM Version  :0x00000101
Bluetooth: hci0: QCA Patch Version:0x00007b40
Bluetooth: hci0: QCA controller version 0x21000101
Bluetooth: hci0: HFP non-HCI data transport is supported
Bluetooth: hci0: AOSP extensions version v1.03
```

`bluetoothctl list` → `Controller 3C:EF:A5:29:6A:62 jc [default]`, `Powered: yes`,
`Discoverable: yes` (see `evidence/kernel-bluetooth-working-boot.log`).

**One residue, documented rather than chased:** the driver then asks for
`qca/hmtbtfw11.tlv` and gets `-2`. We have `hmtbtfw20.tlv` ("`BTFW.HAMILTON.2.0.5-00020`"), so
the patch never lands and the chip runs on ROM firmware. Bluetooth works regardless; see
`NEXT-STEPS.md` item 6.

---

## 2. Reproduce it

### Prerequisites

- The A16 in the starting state: Ubuntu installed on the internal disk, booting in ACPI mode,
  network via the dock, `sudo` available.
- `~/a16-payload/` with the exported payload — in particular
  `zenbook-a16-7.3.0-rc3-next-20260914.tar.zst` (195,503,048 B, sha256 `2cb362c2…`). **Not in
  this repo** (195 MB); it comes from the build payload / the export stick.
- The repo clone: `tools/a16-git-pull.sh` stages a GitHub token (never in argv or a URL) and
  clones `jc372/A16Build`, branch `bringup-2026-09-16`.
- Packages: `device-tree-compiler` (`dtc`), `zstd`, `python3`. Wi-Fi board-data work also wants
  `python3`, `zstd`; the BT firmware install uses the committed tree.
- Free space: ~700 MB in `/lib/modules` for the kernel bundle.
- Patience for **three reboots** (the DT bootstrap, the Wi-Fi verify if you re-install
  firmware, and the Bluetooth DTB).

### The pipeline

```bash
# from anywhere, as the operator (root steps will prompt):
bash BRINGUP/reproduce.sh --check          # read-only: preflight + current state
sudo bash BRINGUP/reproduce.sh --from 10   # run the steps in order
```

Steps: `00-preflight` → `10-kernel` → *(reboot into a DT entry)* → `20-dt-boot` →
`30-firmware` → `40-wifi` → `50-bluetooth` → *(reboot)* → `60-verify`.

`reproduce.sh --list` prints the order and what each step needs. Each `steps/NN-*.sh` is a
wrapper: it checks prerequisites, calls the tool in `tools/`, and states the expected outcome —
so it is also the reference for doing a step by hand.

### Doing it by hand (the same commands, in order)

```bash
sudo bash tools/a16-install-next-kernel.sh        # 10: kernel + modules + DTB + the 9-entry menu
# reboot, choose a DT entry ([1] on this machine)
bash tools/a16-dt-verify.sh                       # 20: internal input, panel, i2c
sudo bash tools/a16-stage-dt-boot.sh              # 20: (re)write the DT entries if needed
sudo bash tools/a16-install-firmware.sh           # 30: DSP firmware
sudo bash tools/a16-bt-setup.sh install           # 30: Bluetooth blobs into /lib/firmware/qca
sudo bash tools/a16-wifi-bdf-test.sh              # 40: serve the QCC2072 board data
sudo bash tools/a16-wifi-tune.sh                  # 40: profile tuning (optional)
sudo bash tools/a16-bt-dtb.sh --install           # 50: build + install + arm the BT DTB
# reboot (no menu interaction needed — the armed paths carry it)
bash tools/a16-bt-setup.sh status                 # 50: is the chip talking?
bash steps/60-verify.sh                           # 60: the acceptance checks
```

### The acceptance checks (`steps/60-verify.sh`)

- live DT contains `qcom,wcn7850-bt`, 6 of 6 stub rails, `uart14` still `okay`;
- the kernel log carries a `QCA controller version` line **and** `bluetoothctl show` reports
  `Powered: yes` (this kernel exposes no `address`/`name` attributes on `hci0` -- only `power`,
  `reset`, `rfkill0` -- so sysfs cannot be the verdict);
- `wlP4p1s0` is up and associated;
- internal input devices present (`Asus Keyboard`, `093A:3012 Touchpad`);
- the DSPs are up and the audio card exists (sound itself is a known open item);
- prints the battery/suspend state for the record.

---

## 3. Script reference

`tools/` = the implementations (each carries its own header explaining what and why). `steps/` =
the ordered wrappers. All of them write a timestamped log to `~/a16-payload/A16*.log` and echo
the log path; none of them needs a separate manual.

| Tool | What it does, and why |
|---|---|
| `a16-install-next-kernel.sh` | Installs the pinned linux-next kernel + modules + the machine DTB + an initramfs, and writes the 9-entry boot menu to the four ESP configs. The whole DT route depends on this. |
| `a16-stage-dt-boot.sh` | Puts the machine DTB on the ESP and writes the DT boot entries with the `acpi=off` + cleanup-ignore + display-blacklist command line. |
| `a16-dt-verify.sh` | After a DT boot: collects the evidence that internal input/panel/i2c came up. |
| `a16-boot-report.sh` | Writes a full state report (display, input, clocks, regulators, dmesg, sessions) to `/boot/efi/a16-reports/<ts>-<mode>-<bootid>/`, so a dark panel can be explained afterwards. |
| `a16-enable-boot-report.sh` | Installs that report as a systemd oneshot, so every boot self-reports. |
| `a16-display-probe.sh` | Reproduces the display bring-up failure on demand in a boot where `msm` is enabled (entry [3]). |
| `a16-install-firmware.sh` / `a16-fix-dsp.sh` | Installs the DSP blobs and brings ADSP/CDSP up live. |
| `a16-install-tplg.sh` / `a16-audio-graph-test.sh` / `a16-sound-test.sh` | The audio chain: give the card a topology, swap topologies, and measure whether a stream is actually consumed. The measurement is what proved the block is upstream (see `notes/2026-09-16-hermes-audio-state.md`). |
| `extract-windows-a16-firmware.sh` | Provenance for the committed Windows firmware tree. |
| `make-a16-qcc2072-board-2.sh`, `ath12k-bdencoder`, `ath12k-bdf-from-elf.py` | Build this machine's `board-2.bin` from its own vendor image (reproduces the committed hash). |
| `a16-wifi-bdf-test.sh` | Install/verify candidate board data for `ath12k` (`--dry-run`, `--verify`). |
| `a16-wifi-tune.sh` | The non-board-data Wi-Fi fixes (band/BSSID preference, powersave, route). |
| `a16-wifi-recover.sh` | **`reload_wifi`**: after a suspend/resume the radio's firmware stops answering (`failed to resume core: -110`, then `wmi command … timeout` forever) and the interface cannot be brought up. **Measured 2026-09-17: nothing recovers it** — NetworkManager/wpa_supplicant restarts do nothing, unbind/bind leaves the netdev gone, and the module unload froze the machine. So the default run does the two harmless rungs and says so; the four driver-teardown rungs need `A16_I_KNOW=1`. `status` is read-only. |
| `a16-session-apps.sh` | Saves visible open app IDs before graphical-session shutdown and relaunches them at next login; relaunch only, not window/tab contents. |
| `a16-gdm-session-fix.sh` | `gdmfix`: disables logind lingering for `jc`, preventing `user@1000.service` from starting before the greeter; takes effect after the next full boot and lets the Hermes Gateway start at login. |
| `a16-sleep-test.sh` | **`lid_sleep`**: the lid switch and logind's policy for it, this boot's suspend attempts and the device that aborts them, and `test [n]`, which suspends for real and reports whether the machine slept. |
| `a16-install-console-commands.sh` | Installs those two commands into `/usr/local/bin` (and `~/`) as symlinks so `reload_wifi --help` / `lid_sleep --help` work from anywhere; `status` lists what is installed, `remove` takes it out. |
| `a16-bt-setup.sh` | BT state, firmware install, and the legacy `btattach` path (kept: it documents why a tty can never exist here). |
| `a16-bt-dtb.sh` | Builds the patched DTB (serdev client + 6 stub rails + the kill-line flip), verifies it by re-decompiling, writes the sha sidecar, installs it, and (with `--install`) arms it. |
| `a16-bt-arm.sh` | Arms/disarms the DT entries' DTB paths (with `.a16stock` backups and sha-pinned both directions) so a boot gets the patched DTB without menu interaction. |
| `a16-bt-enable.sh` | Probe for the module's kill lines. Superseded for the BT blocker (the line belongs to `pwrseq-pcie-m2`, so the export is `EBUSY`); kept for the read-out. |
| `a16-grub-dedupe.sh` | Removes duplicate copies of the BT menu entry (see §4) and re-checks the result with `grub-script-check`. |
| `a16-triage.sh` | The broad hardware triage collector (devices, drivers, firmware, `17cb` inventory). |
| `a16-boot-snapshot.sh` | Late (45 s in) per-boot snapshot to the **internal disk**: DRM/backlight, deferred probes, dmesg, `clk_summary`, regulator summary, the panel pins' pinctrl state, the kernel journal. This is the evidence collector for boots whose picture dies — the older report unit runs ~1 s in and its ESP sink has silently lost writes. |
| `a16-build-gpucc-module.sh` | **build side** (WSL/VM). The installed kernel was built with `# CONFIG_CLK_GLYMUR_GPUCC is not set`, so the GPU's power/clock domain has no driver and msm cannot bind (black screen). This enables that one symbol and rebuilds *only* `drivers/clk/qcom`, then checks the module's vermagic against the running kernel and packages the `.ko` for transfer. |
| `a16-install-gpucc-module.sh` | A16 side. Installs that `.ko` into `/lib/modules/<ver>/kernel/drivers/clk/qcom/`, runs `depmod`, and **refuses a vermagic mismatch** before touching anything. `--check` is read-only and answers "is the display blocked by a missing module right now?". |
| `a16-build-gpucc-native.sh` | Builds that module **on the A16 itself**: `--fetch` (no root) pulls the exact linux-next commit the running kernel was built from, drops in the running kernel's own config with `CONFIG_CLK_GLYMUR_GPUCC=m`, and harvests a `Module.symvers` from the installed modules' `__versions` sections so `CONFIG_MODVERSIONS` CRCs and vermagic match; `--build` compiles only `drivers/clk/qcom` and verifies vermagic + the `module_layout` CRC. |
| `a16-edp-debug.sh` | Live capture for the remaining panel problem: turns on `drm.debug`, forces `card1-eDP-1` to re-detect and its CRTC off/on (re-running eDP link training), and writes the kernel's own account plus the panel path's regulator/clock/GPIO/pinctrl state to `~/a16-payload/edp-debug-<stamp>/`. |
| `a16-enable-boot-snapshot.sh` | Installs that snapshot as a systemd oneshot (`--remove` takes it out). |
| `a16-power-watch.sh` | Samples the power supplies across an unplug/replug and summarises the phases (AC state, battery status, percentage, power, voltage). Read-only; used to confirm the gauge and the ASUS conservation thresholds. |
| `a16-git-pull.sh` | Clone/pull this repo with a staged token that never appears in argv or a URL. |
| `a16-hermes-setup.sh` | Puts Hermes (program + state) on the machine offline, which is why an agent could work on the hardware directly at all. |

---

## 4. Defects found on the way, fixed and recorded

These are the mistakes that cost time; they are documented so nobody repeats them, and the
scripts now guard against each.

1. **"Reboot and pick row [8]" was unfalsifiable.** Entries [1], [2] and [8] carry the *identical*
   kernel command line, so nothing in a boot's own logs says which row ran. Two reboots landed on
   the default entry and looked like the patch failing. → the live DT (`dtc -I fs`) is the
   evidence, and `a16-bt-arm.sh` removes the menu from the critical path entirely.
2. **`grep -q "[8] …"` is a character class.** In a basic regex `[8]` matches the single
   character `8`, so the "is the entry already there?" check in `a16-bt-dtb.sh` never matched and
   every install appended another copy — this machine's four configs each ended up with the entry
   **twice**. → the check now uses `grep -Fq` on the DTB filename; `a16-grub-dedupe.sh` cleans up
   what the old check wrote (verified on copies: 10 → 9 menuentries, one surviving entry intact,
   `grub-script-check` clean).
3. **`hci0` existing is not success.** The serdev bind creates it even when the driver cannot
   power the chip on, and `a16-bt-enable.sh` reported "VERDICT: hci0 is here" on that basis. →
   the verdict is a non-empty `/sys/class/bluetooth/hci0/address`.
4. **A debugfs grep that missed the leading space.** `/sys/kernel/debug/gpio` prints
   ` gpio-628 (…)`, so `grep -m1 "^gpio-628 "` found nothing and the script reported "claimed by
   nothing" for a line that was in fact owned by a driver. → `grep -m1 "gpio-$l "`.
5. **A log path resolved before the `sudo` HOME redirect.** `a16-bt-dtb.sh` computed its log path
   from `$HOME` *before* switching `$HOME` to the invoking user's, so the run that fixed Bluetooth
   logged to `/var/tmp` where the operator would not look. → the redirect now happens first (the
   sibling scripts already did it).
6. **Invented firmware filenames.** An earlier status list named files that do not exist
   (`hmtnv20.bin`, `…b107`, `…b108`); `btqca` derives its names from the chip
   (`qca/hmtbtfw%02x.tlv`, `qca/hmtnv%02x.b<board-id>`), and the Windows package ships exactly
   four board ids. → the status output now states where the names come from instead of guessing.
7. **A prediction that was half right, stated as fact.** The guess "if it asks for `cln*` it is
   the newer Cologne family and this kernel cannot name it" was based on the Windows *package*
   contents; the chip actually reports `Product ID 0x20` and asks for `hmtbtfw11.tlv`, i.e. the
   HAMILTON/`hmt` family the driver supports. The real residue is a name mismatch (item 6 in
   `NEXT-STEPS.md`), not a missing chip family.
8. **An instruction that could not work, given to the operator anyway.** Entry [4] blacklists
   `phy_qcom_edp`, so the internal DP controller waits on a PHY with no driver, so `msm` can
   never bind — the panel could not possibly come up in that boot, and I recommended it as the
   safe first probe. It still had value (it showed the picture dies *without* msm), but the
   recommendation should have said "this boot cannot succeed; it is only a bisect step".
   **Before handing over a boot step, state what it can and cannot prove.**
9. **Evidence that silently vanished.** The boot report printed `a16 boot report: <path>` for
   the [4] boot and nothing was on disk afterwards: the ESP is FAT, its clock is unset early
   (so mtimes are bogus and the "keep the last 6" pruning sorts garbage), and its root still
   carries `FSCK000*.REC` from a past repair. Evidence sinks are now the internal disk first,
   the ESP last and best-effort, and the writer verifies its own output instead of asserting
   it. **A log line that says "wrote X" is not proof that X exists.**
10. **"The battery gauge is silent" was wrong, and the mistake is instructive.** It came from
   `cat …/qcom-battmgr-bat/capacity` being empty — but that attribute does not exist for this
   driver variant at all (`qcom,glymur-pmic-glink` → `qcom_battmgr`'s X1E80100 property set, which
   deliberately omits `POWER_SUPPLY_PROP_CAPACITY`), while the battery reports everything needed
   through `energy_*`. upower computes the percentage from those and shows 81.8 %, 95 % health,
   42 cycles. **A checks script must not treat "this sysfs file is absent" as "this subsystem is
   broken"** — ask the consumer that would use it (here `upower`) before writing it down. The
   acceptance check now prints upower's view plus the conservation thresholds instead.
9. **A truncated log is not evidence.** The native-build script piped `make` through `tail` into the
   log, so when the build died the log held the last four lines and the real error
   (`scripts/gendwarfksyms/gendwarfksyms.h:6: fatal error: dwarf.h: No such file or directory`) was
   gone. Rule: the log gets the *full* stream, the screen gets the tail, and a failing step must stop
   the run (a `modules_prepare` that failed was allowed to continue until the compile of an unrelated
   module hit the missing `include/generated/asm-offsets.h`). That one omission turned a one-package
   fix into a confusing two-error transcript.


---

## 5. Layout

```
BRINGUP/
  README.md              this file
  NEXT-STEPS.md          the planned work, one item at a time
  reproduce.sh           the driver for the pipeline
  steps/                 ordered wrappers: 00-preflight … 60-verify
  tools/                 implementations (+ tools/config: the menu definitions)
  patches/               the diffs (see patches/README.md)
  evidence/              the logs that show it working (and a test tone)
../archive/2026-09-16-pre-bringup/
                         everything from the earlier era, kept, with its own README
../firmware/             the extracted Windows firmware (an input, not history)
../notes/                the dated evidence notes for this window
../STATUS.md             project status sheet (points here)
```

### Patches

`patches/0001-dt-uart14-bluetooth-serdev-client.patch` — the DTB change, as a readable diff
between the stock DTB decompiled and the patched one (serdev client + six stub rails + the
`w-disable2` flags cell). It is **generated**; the source of truth is `tools/a16-bt-dtb.sh`,
which rebuilds and re-verifies from the stock DTB every time.

`patches/0003-grub-bluetooth-test-entry.patch` — the appended menu entry [8], against the config
as it stood before. The entry is not needed for the armed path (the arming targets the DT entries
directly), but it is the boot-time route and documents the exact command line.

The Wi-Fi board data is a *recipe*, not a text patch: `tools/make-a16-qcc2072-board-2.sh`
reproduces the committed 526,972-byte container with the same sha256.
