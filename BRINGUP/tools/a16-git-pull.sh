#!/usr/bin/env bash
# a16-git-pull.sh -- pull the A16Build repo on this machine, using a GitHub token
#                    that never appears in this script, in argv, or in the URL.
#
#   bash ~/a16-payload/a16-git-pull.sh              # stage the token if needed, then clone/pull
#   bash ~/a16-payload/a16-git-pull.sh --status     # show what is staged, fetch nothing
#   bash ~/a16-payload/a16-git-pull.sh --new-token  # drop the staged token, prompt for a fresh one, pull
#   bash ~/a16-payload/a16-git-pull.sh --check      # stage if needed, then only test the credential (no clone)
#
# The token is read with `read -rs` (no echo, not in history) and stored 0600 in
# ~/.a16-git-token as two lines: username, then token.  git gets it through an askpass
# helper, so it is never embedded in the remote URL and never written into .git/config.
# Only a sha256 prefix and the length of the staged pair are ever printed.
# Needs no sudo: git lives in ~/.local/bin (2.55.0, no-root install).
set -u

REPO="${A16_REPO:-https://github.com/jc372/A16Build.git}"
BRANCH="${A16_BRANCH:-feature/tumbleweed-a16-live-iso}"
DEST="${A16_DEST:-$HOME/A16Build}"
TOKEN_FILE="${A16_TOKEN_FILE:-$HOME/.a16-git-token}"
DEFAULT_USER="${A16_GIT_USER:-jc372}"
ASKPASS="$HOME/.local/git/github-askpass.sh"
LOG="${A16_LOG:-$HOME/a16-payload/A16GITPULL-$(date +%Y%m%d-%H%M%S).log}"
GIT="$HOME/.local/bin/git"
SELF="bash $(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { printf '\n== %s ==\n' "$*" | tee -a "$LOG"; }

PATH="$HOME/.local/bin:$PATH"
: > "$LOG" 2>/dev/null || LOG=/var/tmp/a16-git-pull-$(date +%Y%m%d-%H%M%S).log
: > "$LOG"
say "[a16-git] === a16-git-pull $(date +%Y%m%d-%H%M%S) ==="
say "[a16-git] repo   : $REPO"
say "[a16-git] branch : $BRANCH"
say "[a16-git] dest   : $DEST"

# ---------------------------------------------------------------- git present?
if [ ! -x "$GIT" ] || ! "$GIT" --version >/dev/null 2>&1; then
  say "[a16-git] FATAL: no working git at $GIT"
  exit 1
fi
say "[a16-git] git    : $("$GIT" --version)"

# ---------------------------------------------------------------- askpass helper
mkdir -p "$HOME/.local/git"
cat > "$ASKPASS" <<'EOS'
#!/bin/sh
# prints the staged GitHub username / token, keyed off git's own prompt text
TOKEN_FILE="${A16_TOKEN_FILE:-$HOME/.a16-git-token}"
case "$1" in
  *[Uu]sername*) sed -n 1p "$TOKEN_FILE" ;;
  *)             sed -n 2p "$TOKEN_FILE" ;;
esac
EOS
chmod 700 "$ASKPASS"

# ---------------------------------------------------------------- argument / token state
MODE="${1:-}"
case "$MODE" in
  --status|--new-token|--check|"") ;;
  *) say "[a16-git] unknown argument '$MODE' (use --status, --new-token or --check)"; exit 2 ;;
esac
if [ "$MODE" = "--new-token" ] && [ -e "$TOKEN_FILE" ]; then
  rm -f "$TOKEN_FILE"
  say "[a16-git] cleared the previously staged credential"
fi
fingerprint() { # never prints the token itself
  printf 'sha256:%s len=%s' "$(sha256sum "$TOKEN_FILE" 2>/dev/null | cut -c1-8)" \
                          "$(sed -n 2p "$TOKEN_FILE" 2>/dev/null | tr -d '\n' | wc -c)"
}

if [ ! -s "$TOKEN_FILE" ]; then
  sec "GitHub token needed (classic PAT with 'repo' scope, or fine-grained with Contents: Read and write, on jc372/A16Build)"
  say "[a16-git] nothing staged in $TOKEN_FILE."
  if [ "$MODE" = "--status" ]; then
    say "[a16-git] create one at: https://github.com/settings/personal-access-tokens/new"
    say "[a16-git] then stage it and pull with: $SELF --new-token"
    exit 0
  fi
  printf 'GitHub username [%s]: ' "$DEFAULT_USER"
  read -r A16_USER || A16_USER=""
  [ -n "$A16_USER" ] || A16_USER="$DEFAULT_USER"
  printf 'Paste the token (input hidden, then Enter): '
  read -rs A16_TOKEN || A16_TOKEN=""
  echo
  # a browser copy can carry CR / blank padding; keep only token characters
  A16_USER="$(printf '%s' "$A16_USER" | tr -d ' \t\r\n')"
  A16_TOKEN="$(printf '%s' "$A16_TOKEN" | tr -d ' \t\r\n')"
  if [ -z "$A16_TOKEN" ]; then
    say "[a16-git] no token entered -- nothing fetched."
    exit 1
  fi
  umask 077
  printf '%s\n%s\n' "$A16_USER" "$A16_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  unset A16_TOKEN
  say "[a16-git] staged $TOKEN_FILE (600), username $A16_USER ($(fingerprint)) -- the token itself is not logged anywhere."
else
  say "[a16-git] using staged credential for user $(sed -n 1p "$TOKEN_FILE") ($(fingerprint))"
fi
if [ "$MODE" = "--status" ]; then
  say "[a16-git] nothing fetched (--status).  Re-stage with: $SELF --new-token"
  exit 0
fi
export GIT_ASKPASS="$ASKPASS" A16_TOKEN_FILE="$TOKEN_FILE"
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1
run() { # run <label> <cmd...> -- capture stdout+stderr and the real status
  local label="$1"; shift
  local out status
  out="$("$@" 2>&1)"; status=$?
  say "### [$label] \$ $*"
  say "$out"
  say "### exit: $status"
  return $status
}
authhint() {
  say "[a16-git] that reads as an auth failure.  Check, in this order:"
  say "[a16-git]   1. the username you typed is the account the token BELONGS to (not the repo owner)"
  say "[a16-git]   2. fine-grained token -> Repository access: jc372/A16Build, Permissions: Contents = Read-only"
  say "[a16-git]      (classic token -> the 'repo' scope; no scope = 403)"
  say "[a16-git]   3. the token has not expired, and the paste was one line"
  say "[a16-git] then re-stage with: $SELF --new-token"
}

if [ "$MODE" = "--check" ]; then
  sec "credential check (git ls-remote -- reads nothing, writes nothing)"
  if run "ls-remote" "$GIT" ls-remote "$REPO" "refs/heads/$BRANCH"; then
    say "[a16-git] token ACCEPTED: it can read $REPO"
    exit 0
  fi
  say "[a16-git] token REJECTED -- nothing was cloned, nothing on disk changed"
  authhint
  exit 1
fi

sec "clone or pull"
if [ -d "$DEST/.git" ]; then
  run "fetch" "$GIT" -C "$DEST" fetch --prune origin "$BRANCH" \
    || { say "[a16-git] fetch FAILED (see above)"; authhint; exit 1; }
  run "checkout" "$GIT" -C "$DEST" checkout -q "$BRANCH" || true
  run "fast-forward" "$GIT" -C "$DEST" merge --ff-only FETCH_HEAD \
    || say "[a16-git] not a fast-forward -- left on the current commit, nothing lost"
else
  run "clone" "$GIT" clone --branch "$BRANCH" --single-branch "$REPO" "$DEST" \
    || { say "[a16-git] clone FAILED (see above)"; authhint; exit 1; }
fi

sec "what arrived"
run "log" "$GIT" -C "$DEST" log -8 --date=iso --pretty='%h %ad %s'
run "firmware" "$GIT" -C "$DEST" ls-tree -r --name-only HEAD -- firmware
run "notes" "$GIT" -C "$DEST" ls-tree -r --name-only HEAD -- notes PLANS STATUS.md
say ""
say "[a16-git] on disk at: $DEST"
say "[a16-git] log: $LOG"
exit 0
