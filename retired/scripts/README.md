# scripts/ has moved

The tooling that survives this bring-up now lives in **`../BRINGUP/tools/`**, with the ordered
pipeline in `../BRINGUP/steps/` and the driver in `../BRINGUP/reproduce.sh`.

- Pre-bringup tooling (live-ISO builders, WSL build, ESP staging, harvest, the DT-memory
  experiment) is kept in `../archive/2026-09-16-pre-bringup/scripts/` — nothing was deleted, and
  `git log --follow` still reaches every one of them.
- `../notes/2026-09-16-*.md` and some older documents still spell paths as
  `scripts/a16-…sh`; those names now live under `BRINGUP/tools/`.
