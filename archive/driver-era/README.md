# Driver-era material — archived

These directories belonged to the era when this machine ran a stock kernel plus hand-built
out-of-tree modules, with a patched device tree loaded out of band. That approach is retired:
the current linux-next carries what the machine needs in-tree, and the port in
`BRINGUP/port-2026-10-03/` builds it from source.

| Directory | What it was | Why it is here |
|-----------|-------------|----------------|
| `firmware/` | Device trees built by hand and copied to `/boot` | The build now produces its own DTB from the tree; nothing is loaded out of band |
| `patches/` | The older patch series, pre-port | Superseded by `BRINGUP/port-2026-10-03/patches/`, which is the verified set |
| `scripts/` | Bootstrap and staging helpers, including the module-overlay tooling | Superseded by `BRINGUP/port-2026-10-03/build.sh` and `BRINGUP/tools/` |

Kept rather than deleted because the reasons things were tried are worth not re-deriving. See
`../../docs/RETIRED-out-of-tree-drivers.md` for what was learned and what is still used
(`a16-abi-layout-gate.sh` remains in `BRINGUP/tools/`).
