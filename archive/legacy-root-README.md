# A16Build — bringing up the ASUS Zenbook A16 (UX3607OA) on Linux

Hardware: **ASUS Zenbook A16 UX3607OA**, Qualcomm **Snapdragon X2 Elite "Glymur"** (SoC 8480),
47.6 GB RAM, internal NVMe, OLED eDP panel (2880x1800, 30–120 Hz, 10 bpc), Wi-Fi (`ath12k`),
Bluetooth on the WCN7850-class combo, USB4/USB-C, WSA884x speakers.

Target OS: **Ubuntu 26.10** on the internal disk, kernel **7.3.0-rc3-next-20260914**, built from
linux-next commit `1a1de54f7369cd2b5bac0f265910e60ad3a6b4c3`.

This repository is a bring-up log and a reproducible kit. For each component it records what the
hardware needs, what the kernel provides today, what had to change, and how to reproduce it — with the patches included, in the form they are applied.

## Components

| Component | State | Guide | Patch(es) |
|---|---|---|---|
| Internal eDP panel — display, brightness, refresh | **working** | [docs/display-edp.md](docs/display-edp.md) | `patches/0009` (ours), `patches/0006`+`0007` (posted upstream series) |
| GPU (adreno gen8) and its clock controller | device works; userspace support missing | [docs/gpu-adreno.md](docs/gpu-adreno.md) | none — a build-config fix, see [docs/build.md](docs/build.md) |
| Bluetooth | **working** | [docs/bluetooth.md](docs/bluetooth.md) | `patches/0001` (device tree) |
| Wi-Fi | **working** | [docs/wifi.md](docs/wifi.md) | none |
| Keyboard, touchpad, touchscreen, stylus | **working** | [docs/input.md](docs/input.md) | none |
| Battery, charge control, power key | **working** | [docs/power-battery.md](docs/power-battery.md) | none |
| External display over USB-C / DP alt-mode | **working** — requires the link rate to be capped at the sink's own 5.4 Gbps; one tested monitor (MSI) has an internal DP repeater that never equalizes | [docs/display-outputs.md](docs/display-outputs.md) | `patches/0019` + `0020` (ours), `patches/0008` (posted upstream) |
| External display over HDMI | **working** — 5120x1440 on the tertiary PHY into `hdmi-bridge` | [docs/display-outputs.md](docs/display-outputs.md) | none of its own — the tertiary PHY's clock-domain fix (machine DTS) plus `patches/0019` |
| Speakers / audio | not working | [docs/audio.md](docs/audio.md) | needs a machine ACPI topology (upstream work) |
| Suspend / resume | not implemented | [docs/suspend.md](docs/suspend.md) | none yet |
| Boot-time behaviour options | — | [docs/boot-options.md](docs/boot-options.md) | `patches/0003` (historical) |

## Start here

    docs/index.md            how this repository is organised, and how to read a component page
    docs/build.md            build toolchain, the config/ABI requirement, and the checks
    scripts/a16-bootstrap.sh from a fresh Ubuntu install to the current state

    sudo bash scripts/a16-bootstrap.sh --check     # report what is present and missing
    sudo bash scripts/a16-bootstrap.sh --all       # do everything (idempotent, logged to ~/a16-payload/)

    STATUS.md                the pick-up sheet: what was last done, what is next
    BRINGUP/NEXT-STEPS.md    the work list, one item at a time, with the evidence behind each

## Two ways to run the display

Both are legitimate, and the machine selects between them with kernel command-line options, so
nothing has to be reinstalled to switch. See [docs/boot-options.md](docs/boot-options.md).

- **firmware framebuffer** — the display drivers are not loaded (`msm` and the Glymur display
  clocks, the eDP PHY and the panel are all blacklisted on the command line), so the panel is
  driven by the firmware's framebuffer at one fixed mode. Nothing to maintain; no brightness, no
  refresh choice, no GPU device. This is also what a stock Ubuntu install does on this machine.
- **built display driver** — `msm` plus the Glymur display clock controllers, the eDP PHY and the
  panel driver are loaded. Real modesetting (120 Hz available), working backlight, GPU present.
  This is the state the machine is normally kept in here.

## Layout

    docs/          per-component bring-up guides (start at docs/index.md)
    patches/       every change we carry: ours, and the upstream series we depend on
    patches/retired/  things we tried that made no difference (kept so nobody repeats them)
    notes/         dated findings, including negative results
    evidence/      captured traces, logs and opsses backing the notes
    scripts/       bootstrap, build and helper scripts
    BRINGUP/       the older step-by-step kit (still valid; docs/ is the readable version)
    firmware/      the machine's own firmware, extracted from its Windows install
    archive/       the pre-bring-up era (ISO builders, WSL build, ESP staging, harvests, old plans)

## How work happens here

Everything is done *on the A16 itself*: a Hermes agent runs on the machine, `sudo` steps are handed
over as single `sudo bash <script>` commands, and every script writes a timestamped log to
`~/a16-payload/`. That replaced the earlier loop of building an ISO on WSL, flashing a stick,
booting it and photographing the screen — which is why the ISO-era tooling is archived rather than
deleted.

## Branches

`main` carries this layout. It was fast-forwarded from the bring-up branch on 2026-09-16 (47
commits, no divergence) and again on 2026-10-02 from `bringup-2026-09-16` for the external-display
work (32 commits, no divergence). The earlier era's history is on
`feature/tumbleweed-a16-live-iso`, and its files are in `archive/2026-09-16-pre-bringup/`.
