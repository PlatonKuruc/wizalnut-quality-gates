#!/usr/bin/env bash
# Canary test for pretooluse_git_discard_guard.sh
#   QG_HOOKS_DIR=/path/to/hooks bash test_pretooluse_git_discard_guard.sh
# Builds a throwaway git repo in mktemp. Exit 2 = block, 0 = allow.
# Prints one line per case; exits non-zero when any case fails.
set -uo pipefail
HOOKS_DIR="${QG_HOOKS_DIR:-$HOME/.claude/hooks}"
HOOK="$HOOKS_DIR/pretooluse_git_discard_guard.sh"
[ -f "$HOOK" ] || { echo "❌ hook not found: $HOOK"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/qg_git_discard.XXXXXX"); trap 'rm -rf "$T"' EXIT
OK=0; BAD=0

mkrepo() { # mkrepo <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email canary@example.invalid
  git -C "$1" config user.name canary
  echo base > "$1/a.txt"; echo base > "$1/b.txt"
  git -C "$1" add -A
  git -C "$1" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm base
}

payload() { # payload <tool_name> <command> <cwd>
  python3 -c 'import json, sys
print(json.dumps({"session_id": "gate-canary", "hook_event_name": "PreToolUse", "cwd": sys.argv[3],
                  "tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" "$3"
}

t() { # t <description> <expected_exit> <tool_name> <command> [cwd] [home]
  local rc
  payload "$3" "$4" "${5:-$R}" > "$T/payload.json"
  HOME="${6:-$HOME}" bash "$HOOK" < "$T/payload.json" > /dev/null 2> "$T/stderr"; rc=$?
  if [ "$rc" -eq "$2" ]; then echo "  ✅ $1"; OK=$((OK+1))
  else echo "  ❌ $1 - expected $2, got $rc"; head -5 "$T/stderr" | sed 's/^/       /'; BAD=$((BAD+1)); fi
}

R="$T/repo"; mkrepo "$R"; git -C "$R" branch -q second
FAKE_HOME="$T/home"; mkdir -p "$FAKE_HOME/.claude/hooks"; touch "$FAKE_HOME/.claude/hooks/GIT_DISCARD_OFF"

echo "TESTS - pretooluse_git_discard_guard.sh"
t "clean tree: checkout -- a.txt -> allow"            0 Bash 'git checkout -- a.txt'
echo changed >> "$R/a.txt"
t "dirty file: checkout -- a.txt -> BLOCK"            2 Bash 'git checkout -- a.txt'
t "dirty file: restore a.txt -> BLOCK"                2 Bash 'git restore a.txt'
t "other, clean file: checkout -- b.txt -> allow"     0 Bash 'git checkout -- b.txt'
t "dirty tree: reset --hard -> BLOCK"                 2 Bash 'git reset --hard'
t "dirty tree: clean -fd -> BLOCK"                    2 Bash 'git clean -fd'
t "branch switch is not a discard -> allow"           0 Bash 'git checkout second'
t "cd into the repo is followed -> BLOCK"             2 Bash "cd $R && git checkout -- a.txt" "$T"
t "git -C <repo> is followed -> BLOCK"                2 Bash "git -C $R checkout -- a.txt" "$T"
t "bypass marker DISCARD_OK -> allow"                 0 Bash 'git checkout -- a.txt  # DISCARD_OK'
t "kill switch GIT_DISCARD_OFF -> allow"              0 Bash 'git checkout -- a.txt' "$R" "$FAKE_HOME"
t "other tool (Write) -> allow"                       0 Write 'git checkout -- a.txt'

R2="$T/repo2"; mkrepo "$R2"; echo junk > "$R2/untracked.txt"
t "only untracked files: reset --hard -> allow"       0 Bash 'git reset --hard' "$R2"
t "only untracked files: clean -f -> BLOCK"           2 Bash 'git clean -f' "$R2"
t "outside any repo -> allow"                         0 Bash 'git checkout -- a.txt' "$T"

printf 'not json' > "$T/payload.json"
bash "$HOOK" < "$T/payload.json" > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ✅ broken JSON on stdin -> allow"; OK=$((OK+1))
else echo "  ❌ broken JSON on stdin - expected 0, got $rc"; BAD=$((BAD+1)); fi

echo "──────────────"; echo "  passed: $OK · failed: $BAD"; [ "$BAD" -eq 0 ]
