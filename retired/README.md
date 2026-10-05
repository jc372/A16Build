# retired/ — kept for reference, not in use

Material from the era before this machine ran a self-contained linux-next build. Nothing here
is loaded, applied or built by anything current. It is kept because it is **referable**: the
dated notes and evidence in `BRINGUP/` cite these files by name, and the reasons things were
tried are worth not re-deriving.

**If an older document refers to a bare `patches/...`, `scripts/...` or `firmware/...` path,
this is where it is.** Those documents are a historical record and were left as written.

| Directory | What it was | Why it is retired |
|-----------|-------------|-------------------|
| `firmware/` | Device trees built by hand and copied to `/boot` | The build produces its own DTB from the tree; nothing is loaded out of band |
| `patches/` | The older patch series, pre-port | Superseded by the verified set at the repository root, `patches/` |
| `patches/old-numbering/` | The same patches under the numbering used before the renumbering — `0015-qmp-combo-glymur-v5` where the set now has `0008`, and so on | Nothing applies them. Four were byte-identical to the current files, the other six were older revisions of them. Kept so that references in `docs/` and `BRINGUP/evidence/` still resolve; those references were repointed here when the files moved. |
| `scripts/` | Bootstrap and staging helpers, including the module-overlay tooling | Superseded by `BRINGUP/port-2026-10-03/build.sh` and `BRINGUP/tools/` |

What was learned, and what is still live: `docs/RETIRED-out-of-tree-drivers.md`. One tool from
that era is still in use — `BRINGUP/tools/a16-abi-layout-gate.sh`, because its lesson
(symbol CRCs do not cover inlined struct accessors) applies to any module work on this machine.
