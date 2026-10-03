# AGENTS.md — A16Build (ASUS Zenbook A16 / Snapdragon X2 Elite "Glymur")

Read this before touching the repo. Applies to any agent (Hermes, Codex, Claude Code, etc.).

## Where things live now

- **`BRINGUP/`** — the current era: `README.md` (what was done, why, and how to repeat it),
  `NEXT-STEPS.md` (the work list, one item at a time), `steps/` (the ordered pipeline),
  `tools/` (the implementations), `patches/` (the diffs), `evidence/` (logs that show it working),
  `reproduce.sh` (the driver).
- **`archive/2026-09-16-pre-bringup/`** — the ISO era: live-ISO builders, the WSL/VM kernel build,
  the ESP staging/bootloader repair, the live-session harvest, the old PLANS and the old STATUS.
  Kept for recovery and for facts still cited (the ACPI device IDs, the memory map). Not current.
- **`STATUS.md`** — the pick-up sheet: subsystem state, evidence, open work. Refresh it when you
  finish a session.
- **`notes/`** — dated, signed evidence notes: `YYYY-MM-DD-<author>.md`, facts not chat logs.
- **`firmware/`** — the machine's firmware extracted from its own Windows install, plus the
  rebuilt `ath12k` board data. An *input* to `BRINGUP/`, not history.

## How work happens on this machine

- Everything runs **on the A16 itself**, in a Hermes session on the installed system. The old
  loop (build an ISO on WSL → flash a stick → boot → photograph the screen → analyse elsewhere)
  is archived; only use it to recover a machine that will not boot Linux.
- **The agent has no root.** Root work is handed over as one `sudo bash <script>` command with a
  log path the operator can read, and the script states what each possible outcome means.
- Every script writes a timestamped log to `~/a16-payload/A16*.log` and echoes the path. Resolve
  the log path *after* the `sudo` `HOME` redirect, or the run logs where nobody can read it.
- Scripts that change boot state must take backups (`*.a16stock`, `grub.cfg.a16bak-*`), verify by
  reading back (sha256), support a dry run, and be reversible.
- **Never trust a boot's own logs to say which GRUB entry ran** when the entries' command lines
  are identical: decompile `/proc/device-tree` and look for something only the patched variant
  carries. Prefer removing the menu from a critical path over asking for the right row.

## Ground rules

- **Kernel pin:** linux-next `3d08ff75a47a3e7e2ab45a3bcab6723b4d906422`
  (`7.2.0-rc7-next-20260810`). Do not bump it casually. The installed bundle for this era is
  `7.3.0-rc3-next-20260914` (sha256 `2cb362c2…`).
- **Builds are additive:** Fedora / Ubuntu / Tumbleweed build scripts coexist; never break one to
  change another.
- Real builds run in WSL (`/home/jc/A16Build`) or the Tumbleweed VM (`tw-a16`) — not GitHub
  Actions, not the macOS host.
- Secure Boot is disabled when testing on the A16.
- **DT mode is the working boot path** for the installed system (`acpi=off` + the machine DTB);
  ACPI mode cannot reach the internal keyboard/touchpad on this platform.
- **Branches:** `main` carries this layout (fast-forwarded from `bringup-2026-09-16` on
  2026-09-16, which is kept as the same commit). The ISO era's history is on
  `feature/tumbleweed-a16-live-iso`.
- Before writing a new script, check `BRINGUP/tools/` — most of the operations here already have
  one, with its purpose and its evidence in the header.
