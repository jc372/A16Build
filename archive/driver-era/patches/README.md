# patches/

Every change this repository carries, in `git am` / `git apply -p1` form. Each file opens with a
provenance header: who wrote it, when, the Message-ID, the patchwork/lore link, and its state at the
date we fetched it.

    patches/            the changes we apply (0001 DT, 0006+0007 posted PHY series, 0008 posted msm,
                        0009 ours)
    patches/retired/    experiments that made no difference -- kept as evidence, never applied

Which ones go where:

| Patch | Applies to | Applied by |
|---|---|---|
| 0001 | the machine's device tree (Bluetooth serdev + supplies + `w_disable2` polarity) | `BRINGUP/tools/a16-bt-arm.sh`, or `scripts/a16-bootstrap.sh --options` |
| 0003 | the GRUB menu (historical BT test entry) | not applied; kept for reference |
| 0006, 0007 | the kernel tree (`phy-qcom-edp.c`) | `scripts/a16-bootstrap.sh --patches` |
| 0008 | the kernel tree (`drivers/gpu/drm/msm/dp/`) | not applied by default; matters for DPMS paths |
| 0009 | the kernel tree (`dp_panel.c`) | `scripts/a16-bootstrap.sh --patches` |

The docs pages embed these files verbatim (`scripts/render-docs.py`), so a component page carries
its own patch.

---
These are **documentation** of the changes this bring-up makes to the machine — the scripts in
`../tools/` are the source of truth, and every patch here can be regenerated from the machine in
one command. They are committed so a reader can see, in a diff, exactly what was changed and why.

| Patch | What it is | How it was produced |
|---|---|---|
| `0001-dt-uart14-bluetooth-serdev-client.patch` | The device-tree change: a `bluetooth` serdev client under `serial@a98000` (uart14), six always-on `regulator-fixed` stubs for the ones `hci_qca` requires, and the `w-disable2-gpios` flags cell flipped to `ACTIVE_HIGH` (the module's Bluetooth kill line — see `../README.md` §1 step 50). | `dtc -I dtb` on the stock DTB and on the built one, then `diff -u`. Regenerate with:<br>`bash -c 'dtc -f -I dtb -O dts -o /tmp/a.dts /boot/glymur-asus-zenbook-a16-ux3607oa.dtb.a16stock; dtc -f -I dtb -O dts -o /tmp/b.dts /boot/glymur-a16-bt-test.dtb; diff -u /tmp/a.dts /tmp/b.dts'` |
| `0003-grub-bluetooth-test-entry.patch` | The `[8]` menu entry appended to the four ESP GRUB configs, with the exact kernel command line the DT entries use. Not needed for the *armed* path (which targets the DT entries directly), but it is the boot-time route. | `diff -u` of a pre-append `grub.cfg.a16bak-*` against the current config. |

Numbering leaves room for the change this bring-up still owes: `0002-…` is reserved for the
upstream `pwrseq-pcie-m2` change (add this machine's PCI ID so the driver sequences the Bluetooth
kill line itself — `NEXT-STEPS.md` item 1), after which `0001`'s flags flip can be dropped.

Not in here, because they are recipes rather than text diffs:

- **Wi-Fi board data** — `tools/make-a16-qcc2072-board-2.sh` rebuilds the committed
  `firmware/ath12k-board-2-qcc2072-e14f/board-2.bin` (526,972 B, sha256 `314e2d57…`) from the
  machine's own vendor image.
- **Firmware installs** — `tools/a16-install-firmware.sh` and `tools/a16-bt-setup.sh install`
  copy files into `/lib/firmware`; the inputs are committed under `firmware/`.
- **Kernel + modules + menu** — `tools/a16-install-next-kernel.sh` (the bundle it unpacks is the
  export payload, 195 MB, not committed).
