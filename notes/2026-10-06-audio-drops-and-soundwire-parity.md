# Audio drops that come back by themselves: two mechanisms, one live capture (2026-10-06)

Symptom as reported: sound sometimes just stops, and sometimes comes back on its own. It never stops
mid-playback in the sense of a clean cut -- it is the *device* going away and returning.

## Mechanism 1 -- the sink was being torn down every 5 s (config disagreed with the doc)

`~/.config/wireplumber/wireplumber.conf.d/51-a16-ucm.conf` had

    session.suspend-timeout-seconds = 5

while `docs/audio.md` ("No reboot is needed; a WirePlumber rule and a restart is the whole fix") prescribes
`0`. With 5 the ALSA device is suspended five seconds after the last sound and re-created on the next one.
Live evidence of the state that leaves behind, sampled while idle:

    16:36:21  sink=suspended streams=0   amps=Attached,Attached,Attached,Attached

Changed to `0` (original saved as `~/a16-payload/51-a16-ucm.conf.bak-20261006`). Takes effect on the next
`reload_audio` (user session, never sudo).

## Mechanism 2 -- SoundWire bus faults, caught live (this boot, while audio was playing)

    16:37:55  qcom-soundwire 6c80000.soundwire: qcom_swrm_irq_handler: SWR bus clsh detected
    16:40:01  wsa884x-codec sdw:1:0:0217:0204:00:1: Parity error detected
    16:40:01  wsa884x-codec sdw:1:0:0217:0204:00:0: Parity error detected

after which `sdw:1:0:0217:0204:00:0` sat in **Alert** (attached-but-faulting) while the sink read `running`.
This is the same class as the 2026-10-05 14:50 episode (`SWR bus clsh detected`, then amps UNATTACHED) and the
12:31 one (2 of 4 UNATTACHED). The `clsh` (bus clock stop/hold) precedes the parity errors, so the bus
power transitions are implicated -- which is why mechanism 1 matters: fewer suspends, fewer transitions.

Never write `/sys/bus/soundwire/drivers/*/bind` to force a re-attach: it hangs the machine.

## What is NOT the cause (checked)

- The kernel side of the boot: this boot had 0 ADSP crashes, ADSP `running`, 0 amp attach/detach messages.
- `spa.alsa: hw:0,1p: Channels doesn't match (requested 64, got 4)` / `given audio.channels 64 out of
  range:4-4` -- present in **every** boot (12-26 lines), good and bad alike. Same for the boot-time
  `CMD timeout ... opcode` line. Do not chase these.
- xruns: 0 in the failing boot.

## Tools left in place

    audio-watch [seconds]   log the sink's state transitions, streams and the four amps' status
                            (~/A16Build/BRINGUP/tools/a16-audio-watch.sh, symlinked as ~/bin/audio-watch)
    bootcheck               one line per boot into ~/a16-payload/boot-health.log: link-training result,
                            camera binds, altmode events, fbcon/VT, amps attached n/4, max die temp, AC/battery
                            (~/A16Build/BRINGUP/tools/a16-bootcheck.sh, symlinked as ~/bin/bootcheck)

Reading them together is the point: if `lt-fail=2` lines cluster with one column, that column is the lever;
if the amps column flips in step with the dropouts, mechanism 2 is the live one.
