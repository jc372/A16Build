# Audio — WSA884x speakers

**State: not working, and blocked on upstream work rather than on anything we can patch locally.**

## The hardware

| | |
|---|---|
| Speakers | Qualcomm WSA884x amplifiers over SoundWire |
| SoC audio | LPASS (Audio DSP), `qcom-apm` / `q6apm` / `q6prm`, plus the LPASS macro codecs (`snd_soc_lpass_*`) |
| Machine binding | none — there is no machine driver or ACPI/DT description for *this* laptop |

## Current state

The kernel has the pieces as modules and loads them, but nothing describes how they are wired
together on this board, so the DSP never comes up and the SoundWire codecs are never instantiated:

    qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode
    qcom_pmic_glink / q6apm: present, no machine driver to bind them

There is no sound card: `aplay -l` lists nothing, and `/proc/asound/cards` is empty.

## What is needed

A machine description that ties together the SoundWire links, the WSA884x amplifiers and the LPASS
macros for this board — on Qualcomm laptops that is usually an **ACPI machine driver** (a new
`acpi_match_table` entry plus the topology), because these machines ship with ACPI tables rather
than a device tree for the audio side. That is upstream work: it is the same shape as the existing
`x1e80100` machine drivers, extended for Glymur, and it is not something this repository can produce
by patching a config or rebuilding a module.

## Evidence we already have

- `notes/2026-09-16-hermes-audio-state.md` — the state dump from the machine
- `BRINGUP/NEXT-STEPS.md` item 3 — the plan and its size ("blocked, upstream, biggest single win")

## Verify

    aplay -l
    cat /proc/asound/cards
    journalctl -k -b 0 -o cat | grep -iE 'q6apm|apm|soundwire|wsa884x|lpass' | tail

## Bluetooth audio (a different path)

Bluetooth *audio* is a userspace matter (BlueZ + PipeWire) and does work as far as the transport is
concerned, once both ends are paired. This page is about the internal speakers.

---

## The firmware is not in this repository, and cannot be

Audio does not work on a fresh install. The ADSP and CDSP stay `offline`, no sound card appears, and
the desktop shows **"dummy output"**. Three things are needed, and **none of them can be shipped
here**:

| What | Why it cannot ship | Where it comes from |
|---|---|---|
| `qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn`, `qccdsp8480.mbn`, `adsp_dtbs.elf`, `cdsp_dtbs.elf` | Qualcomm proprietary firmware taken out of the Windows driver packages | **your own machine's Windows install** |
| the audio topology (`GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin`) | same category -- vendor payload | the SoC-matching topology shipped in `linux-firmware`, installed under the name the kernel asks for |
| the UCM profile | not ours | `quic-kdybcio/alsa-ucm-conf`, branch `topic/zenbooka16` |

Wi-Fi, Bluetooth and the GPU are **not** affected -- those blobs come from the standard
`linux-firmware` package. This is audio only.

If the blobs are missing, the kernel says so verbatim:

```
remoteproc1 (adsp): qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn
remoteproc2 (cdsp): qcom/glymur/ASUSTeK/UX3607OA/qccdsp8480.mbn
qcom-apm gprsvc:service:2:1: Direct firmware load for
    qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin failed with error -2
snd-x1e80100 sound: ASoC: failed to instantiate card -2
```

### How we pulled it over

**1. On the Windows side** (Windows or WSL -- it only reads the Windows install, never the Linux
one). `BRINGUP/tools/extract-windows-a16-firmware.sh` walks
`C:\Windows\System32\DriverStore\FileRepository`, keeps the payload files of every Qualcomm
package whose name carries this SoC's id (`8480`), and skips driver code (`.sys`/`.inf`/`.dll`) and
the Windows userspace. Report first, then copy:

```bash
DRY_RUN=1 OUT=/mnt/c/Users/<you>/a16-firmware bash BRINGUP/tools/extract-windows-a16-firmware.sh
         OUT=/mnt/c/Users/<you>/a16-firmware bash BRINGUP/tools/extract-windows-a16-firmware.sh
```

It writes a directory tree plus `MANIFEST.tsv` (what each file is, its package, its sha256) and
`sha256sums.txt`.

**2. Carry the four DSP files to the machine**, under `~/a16-payload/a16-local-firmware/`, with
`sha256sums.txt` beside them. Then, on the A16:

```bash
sudo bash ~/a16-payload/a16-install-firmware.sh    # verifies the hashes, installs into
                                                   # /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/,
                                                   # and starts the ADSP and CDSP live
sudo bash ~/a16-payload/a16-install-tplg.sh        # installs a topology under the name the card
                                                   # asks for (override the source with
                                                   # A16_TPLG_SRC=... if you have your own)
```

Both scripts are idempotent and log to the EFI partition (`/boot/efi/A16-*.log`) so the evidence
survives a crash. `a16-install-tplg.sh` removes cleanly with
`sudo rm /lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin.zst`.

**3. The UCM profile**, from the branch that actually has this machine in it -- see step 3 below.
**4. The desktop rule** that gets PipeWire off ACP and out of "dummy output" -- see step 4 below.

The firmware payload we extracted is deliberately **not** committed here: it is Qualcomm/ASUS
proprietary material and this is a public repository. `retired/firmware/README.md` records what each
piece is and where it legally comes from.
## The three steps that actually produced sound (2026-10-03, working)

Recorded from the message that supplied it. This is the first configuration on this machine
that has produced audio, and it is much simpler than the bring-up path that preceded it.

1. **Run the latest Debian `qcom-firmware-extractor`.** It pulls the ADSP and related blobs out
   of the Windows install into `/lib/firmware/qcom/glymur/` (plus `ASUSTeK/UX3607OA/` with
   `qcadsp8480.mbn`, `qccdsp8480.mbn`, `adsp_dtbs.elf`, `cdsp_dtbs.elf`).

2. **Run the second script it comes with**, then **copy the topology by hand** to
   `/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin`. The manual copy is
   not optional in practice: the machine driver requests that exact name and will not find
   anything named otherwise.

3. **Take the UCM profile for this machine from Konrad Dybcio's branch**, not from the generic
   Qualcomm profile and not from another project's tweak tree:

   ```bash
   git clone https://github.com/quic-kdybcio/alsa-ucm-conf --branch=topic/zenbooka16
   cd alsa-ucm-conf/ucm2/Qualcomm/glymur
   sudo cp *.conf /usr/share/alsa/ucm2/Qualcomm/glymur/
   ```

   Verified commit: **`1b99970a9d5f01d68288c3d09b7ac31f4db5ba4f`** -- *"ucm2: Qualcomm: add ASUS
   Zenbook A16 (UX3607OA)"*, 2026-08-31. That branch is where the A16 profile lives:

   | File | What it is |
   |---|---|
   | `ASUS-Zenbook-A16-UX3607OA.conf` | This machine's profile |
   | `ZenbookA16-HiFi.conf` | Its verb, referenced by the above |
   | `HiFi.conf`, `GLYMUR-CRD.conf`, `Slim7x-HiFi.conf`, `LENOVO-Slim-7x.conf` | The shared GLYMUR / X1E80100 / Slim-7x profiles the branch also carries |

   **Verified working 2026-10-03**: a 440 Hz tone at 5% amplitude (about -26 dB) played through
   `aplay -D hw:0,1` and was audible. Start quiet and raise it from there.

### Why the earlier attempts failed

- The profiles shipped by `alsa-ucm-conf` for `Qualcomm/glymur` are the **X1E80100 reference**
  (`GLYMUR-CRD`), not this laptop. They import, but they do not match this card's PCM layout.
- Installing a profile from another project's tweak tree (`GLYMUR-A16.conf` obtained elsewhere)
  did not produce sound either.
- The card is matched on its ALSA id `GLYMURASUSZenbo` (short) while the driver name is
  `GLYMUR-ASUS-Zenbook-A16-UX3607O`, so any profile has to be reachable under both.

### What the machine had to be right for this to work

- SoundWire enumerates **four WSA8845 amplifiers** (`sdw:1:0:0217:0204:00:{0,1}`,
  `sdw:4:0:0217:0204:00:{0,1}`) and two masters (`sdw-master-1-0`, `sdw-master-4-0`).
- The ADSP remoteproc is running and PDR delivered `msm/adsp/audio_pd`.
- The card exposes `MultiMedia2 Playback`; before any profile is applied it fails with
  `ASoC: no backend DAIs enabled for MultiMedia2 Playback`, and playback opens fail `-22`.

**Do not install a `wsa-mix-boost.service` or a saved `asound.state` from a tweak tree.** One
such service pushes all four WSA mix digital volumes to 90 (+6 dB) pre-amplifier, which is a
speaker-damage risk and is not needed for audio to work. The working enable sequence runs the
codec digital volumes at 81/77 (about 0 dB).

### Leftovers to be aware of

Early attempts installed profiles from another project's tweak tree directly into
`/usr/share/alsa/ucm2/Qualcomm/glymur/` (`GLYMUR-A16.conf`, `MicFeBe.conf`, `SpeakerFeBe.conf`
and a copied `HiFi.conf`). The branch's files superseded the ones that mattered and audio works,
so they were left in place rather than deleted; if the profile is ever reinstalled from scratch,
install **only** `topic/zenbooka16` and do not mix the two sets. Earlier copies of each file are
beside them as `*.prebranch` and `*.orig`.

### Step 4 (desktop): tell PipeWire to use UCM, not ACP

ALSA working is not enough — the desktop still shows **"Dummy Output"** afterwards, because
PipeWire drives the card through the legacy **ACP** path and ACP has no profile for a machine
it does not know:

    api.alsa.use-acp = "true"      <- ACP, so no profiles -> no sink -> Dummy Output

No reboot is needed; a WirePlumber rule and a restart is the whole fix:

```ini
# ~/.config/wireplumber/wireplumber.conf.d/51-a16-ucm.conf
monitor.alsa.rules = [
  {
    matches = [ { api.alsa.card.name = "~GLYMUR.*" } ]
    actions = { update-props = {
        api.alsa.use-acp = false
        api.alsa.use-ucm = true
        session.suspend-timeout-seconds = 0
      } }
  }
]
```

```bash
systemctl --user restart wireplumber
wpctl status        # sink should now read "Built-in Audio (MultiMedia2 Playback (*))"
```

Confirmed 2026-10-03: `Dummy Output` was replaced by `Built-in Audio (MultiMedia2 Playback (*))`
and a `MultiMedia4 Capture` source, with the device moving from `[alsa]` to `[alsa:pcm]`.
The rule lives in the user's config, so it survives reboots.
