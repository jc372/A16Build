#!/usr/bin/env bash
# Apply mailing-list series exactly once.  Already-present patches are skipped.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="${1:?usage: $0 /path/to/linux-tree}"
SERIES_FILE="$ROOT/config/series.env"
FETCH_DIR="${FETCH_DIR:-$ROOT/build/series}"
export PATH="$PATH:$HOME/.local/bin"

[[ -d "$TREE/.git" ]] || { echo "Not a git tree: $TREE" >&2; exit 2; }
command -v b4 >/dev/null || { echo "b4 is required (pipx install b4)" >&2; exit 2; }
source "$SERIES_FILE"
mkdir -p "$FETCH_DIR"

apply_one() {
  local msgid="$1" name="$2" mailbox patches patch count=0 skipped=0
  mailbox="$FETCH_DIR/${name}.mbx"
  patches="$FETCH_DIR/${name}.patches"
  rm -rf "$patches"; mkdir -p "$patches"
  echo "Fetching $name: $msgid"
  # b4 am retrieves and prepares a git-am-ready mailbox without mutating the tree.
  # -n controls the stable mailbox base name; b4 appends .mbx.
  (cd "$FETCH_DIR" && b4 am --no-cover -n "$name" "$msgid")
  git mailsplit -d3 -o"$patches" "$mailbox" >/dev/null
  shopt -s nullglob
  for patch in "$patches"/*; do
    # Cover letters and non-patch replies have no diff and are ignored.
    if ! grep -q '^diff --git ' "$patch"; then continue; fi
    git -C "$TREE" apply --check "$patch" >/dev/null 2>&1 || {
      if git -C "$TREE" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "SKIP already applied: $(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$patch" | head -1)"
        ((skipped+=1)); continue
      fi
      echo "ERROR patch neither applies nor reverses: $patch" >&2
      echo "Rebase/update config/series.env; do not force-apply." >&2
      exit 1
    }
    git -C "$TREE" am --3way "$patch"
    ((count+=1))
  done
  echo "$name: applied=$count skipped=$skipped"
}

# Dependencies precede the board series. Keep this list minimal and explicit.
for i in "${!DEPENDENCY_SERIES_MSGIDS[@]}"; do
  [[ -n "${DEPENDENCY_SERIES_MSGIDS[$i]}" ]] && apply_one "${DEPENDENCY_SERIES_MSGIDS[$i]}" "dependency-$i"
done
apply_one "$A16_SERIES_MSGID" "a16"
