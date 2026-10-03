# Retired: the out-of-tree driver era

Earlier work on this machine loaded hand-built modules beside a stock kernel: an overlay of
`ath12k`, `msm`, the Qualcomm PHY drivers, `samsung_atna33xc20`, and `gpucc-glymur`, with a
staged ABI gate for each candidate. That work is **retired** and is not part of the port.

**Why it is no longer needed:** linux-next now carries what the machine needs. The current
kernel is built entirely in-tree from the snapshot in `../00-from-the-beginning.md`, and the
eleven patches in `BRINGUP/port-2026-10-03/patches/` plus the kernel config are all it takes.
Nothing is loaded from an overlay, and no module is staged from a copied tree.

**What was learned, and is kept:**

| Lesson | Where it lives now |
|--------|-------------------|
| Symbol CRCs do not cover inlined struct accessors; a hand-rolled `make M=` in a copied tree silently re-breaks the ABI | `a16-abi-layout-gate.sh`, still in `BRINGUP/tools/` |
| `srcversion` does not change when struct layouts do — sha256 tells two builds apart | the same tool |
| Build the kernel in-tree and never `make clean` the tree being worked on | `build.sh`, and the readme's method notes |

**What is deliberately gone:** staged module candidates, the overlay directories, the
`ath12k` resume workarounds and their modprobe options, and the per-candidate evidence files
that accompanied them. Kept in the repository history, not carried forward.

**Where the material went:** the driver-era directories are archived under
`retired/` (`firmware/`, `patches/`, `scripts/`) so the repository root shows only
what someone should actually use: this README, `docs/`, and `BRINGUP/`.
