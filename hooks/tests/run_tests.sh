#!/usr/bin/env bash
# Runs every canary test in this directory against QG_HOOKS_DIR (default: ~/.claude/hooks).
#   QG_HOOKS_DIR=/path/to/hooks bash run_tests.sh
# Exit 0 only when every test file exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export QG_HOOKS_DIR="${QG_HOOKS_DIR:-$HOME/.claude/hooks}"
ok=0; bad=0; failed=""
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  if out="$(bash "$t" 2>&1)"; then
    ok=$((ok+1)); printf '✅ %s\n' "$name"
  else
    bad=$((bad+1)); failed="$failed $name"; printf '❌ %s\n%s\n' "$name" "$(printf '%s\n' "$out" | sed 's/^/     /')"
  fi
done
printf '──────────────\n%d test file(s) passed · %d failed%s\n' "$ok" "$bad" "${failed:+ ·$failed}"
[ "$bad" -eq 0 ]
