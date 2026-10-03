#!/usr/bin/env bash
# a16-hermes-setup.sh — put Hermes (program AND state) onto this machine's Linux
# install, offline, from the stick it sits on. No downloads, no setup wizard.
#
# Run it as the normal user (jc), NOT with sudo:
#     cd /media/$USER/<STICK>/a16-payload
#     bash a16-hermes-setup.sh
#
# It writes A16-HERMES-LOG.txt back to that same folder (or $HOME if the stick is
# read-only), so the result is readable from Windows afterwards — no screenshots.
#
# Licences: Hermes Agent is open source (MIT-ish, see the repo); the program tree
# copied here is this machine's own installation including its venv.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$HERE/hermes-program-jc.tar.gz"
STATE="$HERE/hermes-backup-a16.zip"
SUMS="$HERE/sha256sums.txt"
LOG="$HERE/A16-HERMES-LOG.txt"
NEED_HOME=/home/jc

_logbuf=""
say()  { echo "[a16-hermes] $*"; _logbuf="${_logbuf}[a16-hermes] $*"$'\n'; }
step() { say ""; say "=== $* ==="; }
finish() {
  # always leave a readable record behind
  if ! printf '%s' "$_logbuf" > "$LOG" 2>/dev/null; then
    LOG="$HOME/A16-HERMES-LOG.txt"
    printf '%s' "$_logbuf" > "$LOG" 2>/dev/null || true
  fi
  say "log: $LOG"
}
die() { say "FATAL: $*"; finish; exit 1; }

say "started $(date -u 2>/dev/null) UTC  host=$(uname -n)  kernel=$(uname -r)"

# ---------------------------------------------------------------- preconditions
step "preconditions"
[ "$(uname -m)" = "aarch64" ] || die "not aarch64 ($(uname -m)) — this tree was built for aarch64"
[ "$(id -u)" = "0" ] && say "WARNING: running as root; run as the normal user instead. Continuing."
[ "$(id -un)" = "jc" ] || die "this copy expects user 'jc' (the venv and its interpreter paths are absolute); you are '$(id -un)'. Use install.sh + 'hermes import' instead (see INSTRUCTIONS-A16.md)."
[ "$HOME" = "$NEED_HOME" ] || die "this copy expects HOME=$NEED_HOME, got HOME=$HOME. Use install.sh + 'hermes import' instead."
for f in "$PROG" "$STATE"; do
  [ -f "$f" ] || die "missing $f"
done
say "uid=$(id -u) user=$(id -un) home=$HOME  OK"

avail_kb=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
say "free space in $HOME: $((avail_kb/1024)) MB"
need_kb=$((2200*1024))
[ "$avail_kb" -ge "$need_kb" ] || die "need about 2.2 GB free in $HOME, have $((avail_kb/1024)) MB"

# ---------------------------------------------------------------- verify payload
step "verify (sha256)"
cd "$HERE" || die "cannot cd $HERE"
if [ -f "$SUMS" ]; then
  for f in "$(basename "$PROG")" "$(basename "$STATE")"; do
    exp=$(grep -E "^[0-9a-f]{64}[  ]+\*?$f\$" "$SUMS" | awk '{print $1}')
    if [ -z "$exp" ]; then say "WARNING: $f is not listed in sha256sums.txt — cannot verify it"; continue; fi
    got=$(sha256sum "$f" | awk '{print $1}')
    if [ "$exp" = "$got" ]; then say "OK   $f"; else die "CHECKSUM MISMATCH on $f (expected $exp, got $got)"; fi
  done
else
  say "WARNING: no sha256sums.txt beside this script — skipping verification"
fi

# ---------------------------------------------------------------- unpack program
step "unpack the program (code + venv + interpreter)"
if [ -e "$HOME/.hermes/hermes-agent" ]; then
  bak="$HOME/.hermes/hermes-agent.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo old)"
  mkdir -p "$HOME/.hermes"
  mv "$HOME/.hermes/hermes-agent" "$bak" || die "could not move the existing install aside"
  say "moved the existing install to $bak"
fi
mkdir -p "$HOME/.local/bin" "$HOME/.hermes"
tar -xzf "$PROG" -C "$HOME" || die "tar extraction failed"
say "extracted."
[ -x "$HOME/.local/bin/hermes" ] || chmod +x "$HOME"/.local/bin/* 2>/dev/null || true
for b in "$HOME"/.hermes/bin/*; do [ -f "$b" ] && chmod +x "$b" 2>/dev/null; done
say "launchers: $HOME/.local/bin/hermes $HOME/.local/bin/hermes-acp $HOME/.local/bin/hermes-agent"

# ---------------------------------------------------------------- restore state
step "restore state (config, keys, skills, memory, sessions)"
mkdir -p "$HOME/.hermes"
"$HOME/.local/bin/hermes" import --force "$STATE" || die "'hermes import' failed — the program is in place; re-run just this step with: hermes import --force $STATE"
say "import done"

# ---------------------------------------------------------------- PATH
step "PATH"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) say "$HOME/.local/bin already on PATH" ;;
  *) say "adding ~/.local/bin to PATH in ~/.bashrc"
     if ! grep -q 'a16-hermes-setup: PATH' "$HOME/.bashrc" 2>/dev/null; then
       printf '\n# a16-hermes-setup: PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
     fi ;;
esac

# ---------------------------------------------------------------- smoke test
step "smoke test"
say "version: $(timeout 60 "$HOME/.local/bin/hermes" --version 2>&1 | head -3 | tr '\n' ' ')"
say "--- hermes doctor (up to 180 s; needs no network for the local checks) ---"
timeout 180 "$HOME/.local/bin/hermes" doctor 2>&1 | tail -40 | while IFS= read -r l; do say "$l"; done
say "--- end doctor ---"

step "done"
say "next: 'hermes' to talk to it, or run the hardware collector:"
say "  sudo bash $HERE/a16-triage.sh"
say "then copy the a16-triage-*.tar.gz back to Windows with the stick."
say "NOTE: browser tools are not included (their 984 MB to 1.2 GB of browser binaries"
say "      were left behind). If you need them: 'hermes' will offer to fetch them."
finish
