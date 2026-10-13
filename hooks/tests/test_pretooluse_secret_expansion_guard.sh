#!/usr/bin/env bash
# Canary test for pretooluse_secret_expansion_guard.sh
#   QG_HOOKS_DIR=/path/to/hooks bash test_pretooluse_secret_expansion_guard.sh
# Exit 2 = block, 0 = allow. No real keys: only variable NAMES are used.
set -uo pipefail
HOOKS_DIR="${QG_HOOKS_DIR:-$HOME/.claude/hooks}"
HOOK="$HOOKS_DIR/pretooluse_secret_expansion_guard.sh"
[ -f "$HOOK" ] || { echo "❌ hook not found: $HOOK"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/qg_secret_exp.XXXXXX"); trap 'rm -rf "$T"' EXIT
OK=0; BAD=0
FAKE_HOME="$T/home"; mkdir -p "$FAKE_HOME/.claude/hooks"; touch "$FAKE_HOME/.claude/hooks/SECRET_EXPANSION_GUARD_OFF"

t() { # t <description> <expected_exit> <tool_name> <command> [home]
  local rc
  python3 -c 'import json, sys
print(json.dumps({"session_id": "gate-canary", "hook_event_name": "PreToolUse",
                  "tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$3" "$4" > "$T/payload.json"
  HOME="${5:-$HOME}" bash "$HOOK" < "$T/payload.json" > /dev/null 2> "$T/stderr"; rc=$?
  if [ "$rc" -eq "$2" ]; then echo "  ✅ $1"; OK=$((OK+1))
  else echo "  ❌ $1 - expected $2, got $rc"; head -3 "$T/stderr" | sed 's/^/       /'; BAD=$((BAD+1)); fi
}

echo "TESTS - pretooluse_secret_expansion_guard.sh"
t 'incident shape: echo ${MY_API_KEY:-MISSING} -> BLOCK'  2 Bash 'echo ${MY_API_KEY:-MISSING}'
t 'echo $OPENAI_API_KEY -> BLOCK'                         2 Bash 'echo $OPENAI_API_KEY'
t 'printenv GITHUB_TOKEN -> BLOCK'                        2 Bash 'printenv GITHUB_TOKEN'
t 'env | grep -i TOKEN -> BLOCK'                          2 Bash 'env | grep -i TOKEN'
t 'printf "%s" "$DB_PASSWORD" -> BLOCK'                   2 Bash 'printf "%s" "$DB_PASSWORD"'
t 'existence check [ -n "$MY_API_KEY" ] -> allow'         0 Bash '[ -n "$MY_API_KEY" ] && echo set || echo missing'
t 'length ${#MY_API_KEY} -> allow'                        0 Bash 'echo "${#MY_API_KEY} chars"'
t 'prefix via cut -c1-4 -> allow'                         0 Bash 'printf %s "$MY_API_KEY" | cut -c1-4'
t 'output to /dev/null -> allow'                          0 Bash 'echo $MY_API_KEY > /dev/null'
t 'plain echo without a secret variable -> allow'         0 Bash 'echo $HOME $PATH'
t 'curl with a Bearer header (no printing) -> allow'      0 Bash 'curl -s -H "Authorization: Bearer $MY_API_KEY" https://api.example.com/v1/items'
t 'bypass marker SECRET_PRINT_OK -> allow'                0 Bash 'echo $MY_API_KEY  # SECRET_PRINT_OK debugging, own risk'
t 'kill switch SECRET_EXPANSION_GUARD_OFF -> allow'       0 Bash 'echo $MY_API_KEY' "$FAKE_HOME"
t 'other tool (Write) -> allow'                           0 Write 'echo $MY_API_KEY'

echo "──────────────"; echo "  passed: $OK · failed: $BAD"; [ "$BAD" -eq 0 ]
