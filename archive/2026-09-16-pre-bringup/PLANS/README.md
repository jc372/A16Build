# PLANS — A16Build planning & progress

Plans for this project live HERE, in the repo, so any machine or AI working on
this project sees them. This repo is the single source of truth; plan docs
travel with the code via git.

## Convention

- One directory-less flat file per plan: `PLAN-NNN-<short-slug>.md`
  (e.g. `PLAN-001-a16-tumbleweed-build.md`).
- Numbers are sequential and never reused. A superseded plan is marked
  `Status: SUPERSEDED` and linked from the new plan.
- Supporting files (logs, dumps, screenshots) go in `PLANS/notes-<NNN>/` and
  are referenced from the plan.

## PLAN.md required sections

1. **Header** — plan number, title, status, last-updated date.
2. **Objective** — what success looks like, one short paragraph.
3. **Background** — why the task exists; project context.
4. **Key technical facts** — established facts/decisions, so a fresh reader
   does not re-derive them.
5. **Current tasks** — checkbox list; most recent state marked `IN PROGRESS`.
6. **History** — dated log, reverse-chronological.
7. **What worked** — confirmed wins + commands/artifacts to reproduce.
8. **What failed / gotchas** — dead ends, bugs, lessons, with fixes.
9. **Next steps** — exact, runnable commands in order.
10. **References** — files, VMs, URLs.

## Rules

- **AI-agnostic handoff style**: facts, commands, decisions — not chat logs.
  Do not assume the next reader knows the project or which AI wrote it.
- **Keep it current**: update the plan at the end of every working session.
  Move done items to History; record failures even if quickly fixed.
- **One file is the source of truth**: everything needed to continue lives in
  the plan file.
- **Self-contained**: exact paths, commands, and host names (note which
  machine each path is on — macOS coordinator vs WSL vs VM).

## Index

| # | Title | Status | Last updated |
|---|-------|--------|--------------|
| 001 | openSUSE Tumbleweed A16 live-ISO build | IN PROGRESS (paused) | 2026-08-15 |
| 002 | Ubuntu + linux-next fresh build for the A16 | IN PROGRESS — active | 2026-09-16 |
