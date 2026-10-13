#!/usr/bin/env bash
# Canary test for posttooluse_evidence_flags.sh
#   QG_HOOKS_DIR=/path/to/hooks bash test_posttooluse_evidence_flags.sh
# The hook never blocks (exit 0); it appends to /tmp/qg-edits-<sid>.log and
# /tmp/qg-verify-<sid>.log. Each case checks exit 0 + what was (not) logged.
# Prints one line per case; exits non-zero when any case fails.
set -uo pipefail
HOOKS_DIR="${QG_HOOKS_DIR:-$HOME/.claude/hooks}"
HOOK="$HOOKS_DIR/posttooluse_evidence_flags.sh"
[ -f "$HOOK" ] || { echo "❌ hook not found: $HOOK"; exit 1; }
SID="gate-canary"
EDITS="/tmp/qg-edits-$SID.log"; VERIFY="/tmp/qg-verify-$SID.log"
T=$(mktemp -d "${TMPDIR:-/tmp}/qg_evidence_flags.XXXXXX")
FH="$T/home"; mkdir -p "$FH/.claude/hooks"
trap 'rm -rf "$T"; rm -f "$EDITS" "$VERIFY"' EXIT
OK=0; BAD=0

payload() { # payload <tool_name> <tool_input_json> [stdout] [stderr]
  python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "PostToolUse", "cwd": "/work/app",
                  "tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[3]),
                  "tool_response": {"stdout": sys.argv[4], "stderr": sys.argv[5], "interrupted": False}}))' \
    "$SID" "$1" "$2" "${3:-}" "${4:-}" > "$T/in.json"
}
logline() { # last line of a log, or "-" when the log is missing/empty
  if [ -s "$1" ]; then tail -n 1 "$1" | cut -d'|' -f2-; else echo "-"; fi
}
t() { # t <description> <expected "edits=<x> verify=<y>"> <tool_name> <tool_input_json> [stdout] [stderr]
  local rc got
  rm -f "$EDITS" "$VERIFY"
  payload "$3" "$4" "${5:-}" "${6:-}"
  HOME="$FH" bash "$HOOK" < "$T/in.json" >/dev/null 2>&1; rc=$?
  got="rc=$rc edits=$(logline "$EDITS") verify=$(logline "$VERIFY" | cut -d'|' -f1-2)"
  if [ "$got" = "rc=0 $2" ]; then echo "  ✅ $1"; OK=$((OK+1)); else echo "  ❌ $1 — expected [rc=0 $2], got [$got]"; BAD=$((BAD+1)); fi
}

echo "TESTS — posttooluse_evidence_flags.sh"
t "Edit of a code file → edit logged" "edits=Edit|/work/app/main.py verify=-" \
  Edit '{"file_path": "/work/app/main.py", "old_string": "a", "new_string": "b"}'
t "Write of a .md doc → not logged" "edits=- verify=-" \
  Write '{"file_path": "/work/app/README.md", "content": "x"}'
t "Edit of a temp file → not logged" "edits=- verify=-" \
  Edit '{"file_path": "/tmp/scratch_x.py", "old_string": "a", "new_string": "b"}'
t "pytest with passing output → verify ok" "edits=- verify=Bash|ok" \
  Bash '{"command": "pytest -q tests/"}' "12 passed in 0.31s"
t "pytest with FAILED output → verify fail" "edits=- verify=Bash|fail" \
  Bash '{"command": "pytest -q tests/"}' "FAILED tests/test_main.py::test_x - assert 1 == 2"
t "bash -n with 'syntax error' → verify fail" "edits=- verify=Bash|fail" \
  Bash '{"command": "bash -n deploy.sh"}' "" "deploy.sh: line 3: syntax error near unexpected token"
t "plain ls (not a verify) → nothing logged" "edits=- verify=-" \
  Bash '{"command": "ls -la"}' "main.py"
t "bypass marker '# pta-verified' → logged as verify" "edits=- verify=Bash|ok" \
  Bash '{"command": "./smoke.sh  # pta-verified"}' "all good"
t "Skill pta-gate → verify credit" "edits=- verify=Skill|pta-gate" \
  Skill '{"skill": "pta-gate"}'
t "Skill outside the verify list → nothing" "edits=- verify=-" \
  Skill '{"skill": "brief-loop"}'
t "other tool (Read) → nothing logged" "edits=- verify=-" \
  Read '{"file_path": "/work/app/main.py"}'
touch "$FH/.claude/hooks/EVIDENCE_FLAGS_OFF"
t "DISABLE: EVIDENCE_FLAGS_OFF → nothing logged" "edits=- verify=-" \
  Edit '{"file_path": "/work/app/main.py", "old_string": "a", "new_string": "b"}'
rm -f "$FH/.claude/hooks/EVIDENCE_FLAGS_OFF"

echo "──────────────"; echo "  passed: $OK · failed: $BAD"; [ "$BAD" -eq 0 ]
