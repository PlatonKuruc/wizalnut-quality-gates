#!/usr/bin/env bash
# Canary test for stop_no_fabricated_evidence.sh
#   QG_HOOKS_DIR=/path/to/hooks bash test_stop_no_fabricated_evidence.sh
# Builds fake transcript JSONL files in mktemp and runs the hook with a throwaway
# HOME. BLOCK = exit 2 (class 3) or {"decision":"block"} on stdout (classes 1+2).
# Prints one line per case; exits non-zero when any case fails.
set -uo pipefail
HOOKS_DIR="${QG_HOOKS_DIR:-$HOME/.claude/hooks}"
HOOK="$HOOKS_DIR/stop_no_fabricated_evidence.sh"
[ -f "$HOOK" ] || { echo "❌ hook not found: $HOOK"; exit 1; }
SID="gate-canary"
EDITS="/tmp/qg-edits-$SID.log"; VERIFY="/tmp/qg-verify-$SID.log"
T=$(mktemp -d "${TMPDIR:-/tmp}/qg_stop_evidence.XXXXXX")
FH="$T/home"; mkdir -p "$FH/.claude/hooks"
trap 'rm -rf "$T"; rm -f "$EDITS" "$VERIFY"' EXIT
OK=0; BAD=0
GATE="Gate: Wizalnut Quality Gates · stop_no_fabricated_evidence.sh"

mk() { # mk <file> <record>...   records: "u:<text>" user · "a:<text>" assistant · "t:<Tool>:<path or command>"
  python3 - "$@" <<'PY'
import json, sys
out = sys.argv[1]
with open(out, "w", encoding="utf-8") as f:
    for spec in sys.argv[2:]:
        kind, _, rest = spec.partition(":")
        if kind == "u":
            rec = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": rest}]}}
        elif kind == "a":
            rec = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": rest}]}}
        else:
            name, _, arg = rest.partition(":")
            inp = {"command": arg} if name == "Bash" else {"file_path": arg}
            rec = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": name, "input": inp}]}}
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}

LAST_OUT=""; LAST_ERR=""
t() { # t <description> <BLOCK|ALLOW> <transcript> [stop_hook_active]
  local out rc verdict
  python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "transcript_path": sys.argv[2], "hook_event_name": "Stop",
                  "stop_hook_active": sys.argv[3] == "true"}))' "$SID" "$3" "${4:-false}" > "$T/in.json"
  out=$(HOME="$FH" bash "$HOOK" < "$T/in.json" 2>"$T/err"); rc=$?
  LAST_OUT="$out"; LAST_ERR=$(cat "$T/err")
  verdict=ALLOW
  if [ "$rc" -eq 2 ]; then verdict=BLOCK
  elif grep -q '"decision":"block"' <<< "$out"; then verdict=BLOCK
  elif [ "$rc" -ne 0 ]; then verdict="ERROR(rc=$rc)"; fi
  if [ "$verdict" = "$2" ]; then echo "  ✅ $1"; OK=$((OK+1)); else echo "  ❌ $1 — expected $2, got $verdict"; BAD=$((BAD+1)); fi
}
same() { # same <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ✅ $1"; OK=$((OK+1)); else echo "  ❌ $1 — expected [$2], got [$3]"; BAD=$((BAD+1)); fi
}
clean_logs() { rm -f "$EDITS" "$VERIFY"; }

echo "TESTS — stop_no_fabricated_evidence.sh"
clean_logs

# --- class 1: approval attribution ---------------------------------------
mk "$T/c1.jsonl" "u:make the banner" "a:Here it is — exactly what you asked for."
t "class 1: 'exactly what you asked for' → BLOCK" BLOCK "$T/c1.jsonl"
same "class 1: reason ends with the Gate line" "$GATE" "$(jq -r '.reason' <<< "$LAST_OUT" | tail -n 1)"
mk "$T/c1b.jsonl" "u:make the banner" "a:You'll love this one."
t "class 1: 'You'll love this' → BLOCK" BLOCK "$T/c1b.jsonl"
mk "$T/c1ok.jsonl" "u:make the banner" "a:Banner written to out/banner.png (1200x628). Not reviewed by you yet."
t "class 1: bare facts → ALLOW" ALLOW "$T/c1ok.jsonl"
t "class 1: stop_hook_active=true (anti-loop) → ALLOW" ALLOW "$T/c1.jsonl" true

# --- class 2: verdict after a code edit, no run --------------------------
mk "$T/c2.jsonl" "u:fix the parser" "t:Edit:src/parser.py" "a:Fixed, it works now."
t "class 2: edit .py then 'Fixed, it works now.' with no run → BLOCK" BLOCK "$T/c2.jsonl"
same "class 2: reason ends with the Gate line" "$GATE" "$(jq -r '.reason' <<< "$LAST_OUT" | tail -n 1)"
mk "$T/c2read.jsonl" "u:fix the parser" "t:Edit:src/parser.py" "t:Read:src/parser.py" "a:Fixed."
t "class 2: Read after the edit is not a run → BLOCK" BLOCK "$T/c2read.jsonl"
mk "$T/c2run.jsonl" "u:fix the parser" "t:Edit:src/parser.py" "t:Bash:pytest -q" "a:Fixed — pytest: 12 passed."
t "class 2: Bash run after the edit → ALLOW" ALLOW "$T/c2run.jsonl"
mk "$T/c2neg.jsonl" "u:fix the parser" "t:Edit:src/parser.py" "a:Edited src/parser.py — not yet fixed, still failing on empty input."
t "class 2: negated ('not yet fixed') → ALLOW" ALLOW "$T/c2neg.jsonl"
mk "$T/c2byp.jsonl" "u:fix the parser" "t:Edit:src/parser.py" "a:Fixed the typo. BYPASS_KANT (comment-only change)"
t "class 2: BYPASS_KANT → ALLOW" ALLOW "$T/c2byp.jsonl"
mk "$T/c2md.jsonl" "u:update the readme" "t:Edit:README.md" "a:Done."
t "class 2: other kind of edit (README.md, not code) → ALLOW" ALLOW "$T/c2md.jsonl"

# --- class 3: DONE claim vs. session logs ---------------------------------
NOW=$(date +%s)
mk "$T/c3.jsonl" "u:ship it" "a:Deployed and done."
clean_logs; printf '%s|Edit|/work/app/main.py\n' "$((NOW-5))" > "$EDITS"
t "class 3: DONE claim, edit logged, no verify → BLOCK (exit 2)" BLOCK "$T/c3.jsonl"
same "class 3: stderr ends with the Gate line" "$GATE" "$(printf '%s\n' "$LAST_ERR" | tail -n 1)"
printf '%s|Bash|ok|/work/app|pytest -q\n' "$NOW" > "$VERIFY"
t "class 3: ok verify after the edit in the same tree → ALLOW" ALLOW "$T/c3.jsonl"
printf '%s|Bash|fail|/work/app|pytest -q\n' "$NOW" > "$VERIFY"
t "class 3: failed verify after the edit → BLOCK" BLOCK "$T/c3.jsonl"
printf '%s|Bash|ok|/elsewhere|npm test\n' "$NOW" > "$VERIFY"
t "class 3: unrelated verify (other dir, file not named) → BLOCK" BLOCK "$T/c3.jsonl"
mk "$T/c3byp.jsonl" "u:ship it" "a:Deployed and done. BYPASS_PTA (config-only deploy)"
t "class 3: BYPASS_PTA → ALLOW" ALLOW "$T/c3byp.jsonl"
mk "$T/c3neg.jsonl" "u:ship it" "a:Patched main.py, but it is not done yet — still failing on staging."
t "class 3: negated DONE near the end → ALLOW" ALLOW "$T/c3neg.jsonl"
t "class 3: still enforced when stop_hook_active=true → BLOCK" BLOCK "$T/c3.jsonl" true
clean_logs
t "class 3: no edits log → ALLOW" ALLOW "$T/c3.jsonl"

# --- disable switch -------------------------------------------------------
touch "$FH/.claude/hooks/FABRICATED_EVIDENCE_OFF"
t "DISABLE: FABRICATED_EVIDENCE_OFF → ALLOW" ALLOW "$T/c1.jsonl"
rm -f "$FH/.claude/hooks/FABRICATED_EVIDENCE_OFF"

echo "──────────────"; echo "  passed: $OK · failed: $BAD"; [ "$BAD" -eq 0 ]
