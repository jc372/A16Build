# How to read these pages

Each page covers **one component**: what the hardware is, what the kernel does with it today, what
had to be changed to bring it up, how to verify it, and what is still missing. Everything about one
change is in one place: the page carries its patch verbatim, at the bottom.

## The two display modes

This machine runs its display stack in one of two modes, selected on the kernel command line
(see [boot-options.md](boot-options.md)). Nothing else in the repository depends on which one is in
use; the display pages state which one they describe:

- **firmware framebuffer** — the display drivers are not loaded; the panel is driven by the
  firmware's framebuffer at one fixed mode.
- **built display driver** — `msm`, the Glymur display clocks, the eDP PHY and the panel driver are
  loaded, giving real modesetting, a backlight, and a GPU device.

Other components (Bluetooth, Wi-Fi, input, power) are the same either way.

## Patch provenance legend

Every patch we carry is labelled with where it came from, because that decides what to do with it:

| Label | Meaning | What to do |
|---|---|---|
| **ours** | we wrote it, it is a workaround for a driver/kernel gap | carry it; replace it when a real fix lands |
| **posted upstream** | someone posted it to a list; it is in patchwork, *not* merged | carry it, with its provenance recorded |
| **upstream, unmerged** | as above but post-dates our kernel tree | ditto |
| **retired** | we tried it and it made no difference | kept as evidence in `patches/retired/`; do not apply |

Patch files carry a provenance header (author, date, Message-ID, patchwork link, state at the date
we fetched it) above the diff. Where a patch is small and ours, the page includes it inline; where
it is a posted series, the page includes it inline as well, so the whole change is in one place.

## Conventions

- Every claim is backed by a command, quoted as it was run.
- Failures and negative results are kept, with what ruled them out.
- Where a step needed a specific command, the command is in the page.
- Scripts are idempotent and log to `~/a16-payload/`.

## The pages

| Page | Component |
|---|---|
| [display-edp.md](display-edp.md) | the internal panel: eDP link, brightness, refresh rates |
| [gpu-adreno.md](gpu-adreno.md) | the GPU device, its clock controller, and userspace support |
| [bluetooth.md](bluetooth.md) | Bluetooth over the WCN7850-class combo |
| [wifi.md](wifi.md) | Wi-Fi (`ath12k`) |
| [A16 ath12k maintainer handoff](../BRINGUP/notes/2026-09-30-ath12k-maintainer-handoff.md) | QCC2072 board-data mismatch, upstream report link, and separate PCIe resume evidence |
| [input.md](input.md) | keyboard, touchpad, touchscreen, stylus |
| [power-battery.md](power-battery.md) | battery gauge, charge control, power key |
| [display-outputs.md](display-outputs.md) | external displays over USB-C / DP alt-mode |
| [audio.md](audio.md) | speakers (blocked upstream) |
| [suspend.md](suspend.md) | suspend/resume |
| [build.md](build.md) | the build toolchain, the config/ABI requirement, and the checks |
| [boot-options.md](boot-options.md) | command-line options: firmware framebuffer vs built driver |
