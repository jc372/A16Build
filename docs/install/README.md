# Install steps — Windows to a working Ubuntu

These steps take a Windows-only machine to a booting Ubuntu, on this hardware, with no second
computer. They were the front door of the `A16UbuntuBuild` repository, which is now archived;
everything lives here so the story is in one place.

Provenance: copied from `A16UbuntuBuild` at its final state (that repository's own README and
`steps/`), which is preserved in `archive/`. The steps describe installing Ubuntu on this
machine; the kernel work that follows is in `../00-from-the-beginning.md`.

| Step | |
|------|---|
| `00-prepare-in-advance.md` | What to have ready before you start |
| `01-build-installer-media.md` | Writing the installer media |
| `02-install-ubuntu.md` | The install itself, including the clock and Secure Boot traps |
| `03-stage-repair-scripts.md` | Keeping a way back into the machine |
| `04-finish-the-boot.md` | Getting to a usable desktop |
| `05-bring-up.md` | The bring-up that follows the install |

`06-module-builds.md` describes the out-of-tree module work and is **retired** — see
`../RETIRED-out-of-tree-drivers.md`. It is kept only as a record.

Read `../00-from-the-beginning.md` first: it is the whole arc, including the hub requirements
and where the kernel comes from.
