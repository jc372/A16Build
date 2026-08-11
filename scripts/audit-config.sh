#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:?usage: $0 /path/to/.config}"
REQUIRED="${2:-$ROOT/config/a16-required.config}"
missing=0

while IFS= read -r requirement; do
  if [[ "$requirement" =~ ^CONFIG_[A-Za-z0-9_]+= ]]; then
    symbol="${requirement%%=*}"
    actual="$(grep -E "^${symbol}=" "$CONFIG" | tail -n1 || true)"
  elif [[ "$requirement" =~ ^\#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
    symbol="${BASH_REMATCH[1]}"
    actual="$(grep -E "^(# ${symbol} is not set|${symbol}=)" "$CONFIG" | tail -n1 || true)"
    # Hidden Kconfig symbols are omitted entirely once their parent option is
    # disabled. An absent line is therefore equivalent to "not set" here.
    [[ -z "$actual" ]] && actual="$requirement"
  else
    continue
  fi
  if [[ "$actual" != "$requirement" ]]; then
    printf 'MISSING %-42s expected=%s actual=%s\n' "$symbol" "$requirement" "$actual" >&2
    missing=1
  else
    printf 'OK      %s\n' "$requirement"
  fi
done < "$REQUIRED"

if (( missing != 0 )); then
  echo "A16 kernel configuration audit failed" >&2
  exit 1
fi
echo "A16 kernel configuration audit passed"
