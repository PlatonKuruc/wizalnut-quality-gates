#!/usr/bin/env bash
# ============================================================================
# stop_no_fabricated_evidence.sh — Stop hook
# ============================================================================
# WHAT:    Refuses to end the turn when the last assistant message (1) puts
#          approval or a preference in the user's mouth, (2) claims "fixed /
#          works / done" after a code edit in this turn with no run after that
#          edit, or (3) claims DONE while the session's last code edit has no
#          usable verify after it.
# WHY:     Field incident, 07/2026: a sync script was reported "fixed ✅" with
#          no run after the edit. Nobody re-checked it; it stayed dead for 16
#          days. Rule: claim only what an output in front of you shows.
# BYPASS:  class 2: BYPASS_KANT in your message (or in the user's last prompt)
#          class 3: BYPASS_PTA in your message
#          class 1 has no marker: if the user really said it, quote them.
# DISABLE: touch $HOME/.claude/hooks/FABRICATED_EVIDENCE_OFF
# TEST:    $HOME/.claude/hooks/tests/test_stop_no_fabricated_evidence.sh
#
# Class 1  approval attribution — trip-wire phrases ("exactly what you asked
#          for", "you'll love this", ...) → block, rephrase to bare facts.
# Class 2  verdict without a run — a verdict ("fixed", "works now", "done",
#          "✅ ...") after an Edit/Write of a code file in the same turn, with no
#          tool call after the last edit other than reading (Read/Grep/... is
#          reading your own change, not a run). Negated phrases ("not done",
#          "not yet fixed") do not count.
# Class 3  DONE claim vs. session logs — /tmp/qg-edits-<sid>.log has an edit
#          newer than the last USABLE verify in /tmp/qg-verify-<sid>.log
#          (usable = result ok AND related to the edited file: same directory
#          tree, or the file named in the command). Logs are written by
#          posttooluse_evidence_flags.sh — install both.
#
# Output:  classes 1+2 → {"decision":"block","reason":...} on stdout, exit 0;
#          class 3 → message on stderr, exit 2.
# Anti-loop: when stop_hook_active is true, classes 1+2 are skipped; class 3
#          still runs (a DONE claim must be verified or withdrawn).
# Requires: bash 3.2+, jq, python3.
# ============================================================================
set -euo pipefail
# grep -q reads via <<<, never from a pipe: under pipefail the writer would get
# SIGPIPE and the pipeline would return 141.
[ -f "$HOME/.claude/hooks/FABRICATED_EVIDENCE_OFF" ] && exit 0
input=$(cat)
GATE_LINE="Gate: Wizalnut Quality Gates · stop_no_fabricated_evidence.sh"

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)

if [ "$active" != "true" ] && [ -n "${tp:-}" ] && [ -f "$tp" ]; then

# last assistant text message from the transcript JSONL
last=$(tail -n 200 "$tp" | jq -rs '
  map(select(.type=="assistant"))
  | last
  | (.message.content // [])
  | map(select(.type=="text") | .text) | join("\n")
' 2>/dev/null || true)

if [ -n "${last:-}" ]; then

# ---------------------------------------------------------------------------
# Class 1 — high-signal trip-wire phrases (attributing approval / preference)
# ---------------------------------------------------------------------------
re="you liked (it|this|that)|what you like|(like|as) you wanted|exactly what you (asked for|wanted|had in mind|pictured|envisioned|imagined)|you(’|')ll love (it|this)|you will love (it|this)|you(’|')re going to love|as you preferred|the way you like it|looks great, done|done and looks great|it looks beautiful"

if grep -iqE "$re" <<< "$last"; then
  m=$(grep -ioE "$re" <<< "$last" | sed -n '1p')
  jq -nc --arg m "$m" --arg g "$GATE_LINE" '{
    decision: "block",
    reason: ("🚫 Do not fabricate approval — you wrote “" + $m + "”, which attributes a reaction, approval or preference to the user. Did they say it LITERALLY in this conversation? If not → rephrase to bare facts: WHAT you did + WHAT you verified (not their feelings). Let the user voice their own reaction. (If they really said it, keep it — but check.)\n" + $g)
  }'
  exit 0
fi

# ---------------------------------------------------------------------------
# Class 2 — verdict after a code edit with no run after it
# ---------------------------------------------------------------------------
VERDICT=$(tail -n 600 "$tp" | python3 -c '
import json, re, sys

EDIT = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
READING = {"Read", "Grep", "Glob", "LS", "TodoWrite", "TodoRead", "Skill", "ToolSearch", "Agent", "AskUserQuestion"}
CODE = re.compile(r"\.(sh|py|js|mjs|cjs|ts|tsx|jsx|html|css|sql|json|plist|go|rs|rb|swift|yaml|yml|toml)$", re.I)
VERDICTS = [
    r"✅ ?(fixed|done|works|working|resolved|deployed|running|pass(es|ed|ing)?)",
    r"\b(is|are) (now )?fixed\b", r"fixed and verified", r"\bi(\x27ve| have)? fixed\b",
    r"\b(it )?works now\b", r"\bnow (it )?works\b", r"works ✅", r"\bworks\.\s*$",
    r"matches the reference", r"everything (works|matches|passe[sd])", r"\bdone\b",
    r"\bfixed\b", r"\bresolved\b", r"\bdeployed\b",
]
# "not done", "not yet fixed", "has not been deployed", "isn\x27t fixed" are not verdicts
NEGATED = re.compile(r"\b(not|isn[\x27’]t|aren[\x27’]t|wasn[\x27’]t|weren[\x27’]t|haven[\x27’]t|hasn[\x27’]t|never|no longer)\s+(yet\s+)?(be(en)?\s+)?(fully\s+)?\w+")

def blocks(rec):
    msg = rec.get("message") or {}
    c = msg.get("content")
    return c if isinstance(c, list) else ([{"type": "text", "text": c}] if isinstance(c, str) else [])

last_agent, last_user, steps = "", "", []
for ln in sys.stdin:
    try:
        r = json.loads(ln)
    except Exception:
        continue
    role = (r.get("message") or {}).get("role") or r.get("type")
    txt = "\n".join(b.get("text") or "" for b in blocks(r) if b.get("type") == "text")
    if role == "user" and txt.strip():
        last_user, last_agent, steps = txt, "", []
    elif role == "assistant":
        if txt.strip():
            last_agent = txt
        for b in blocks(r):
            if b.get("type") == "tool_use":
                inp = b.get("input") or {}
                steps.append((b.get("name") or "", inp.get("file_path") or inp.get("path") or ""))

if not last_agent.strip() or "BYPASS_KANT" in last_agent or "BYPASS_KANT" in last_user:
    sys.exit(0)
body = re.sub(r"```.*?```", " ", last_agent, flags=re.S).lower()
body = NEGATED.sub(" ", body)
hit = next((m.group(0) for p in VERDICTS for m in [re.search(p, body, re.M)] if m), None)
if not hit:
    sys.exit(0)

last_edit = -1
for i, (n, fp) in enumerate(steps):
    if n in EDIT and CODE.search(fp or ""):
        last_edit = i
if last_edit < 0:
    sys.exit(0)                       # no code edit in this turn → not this class
ran = any(n not in EDIT and n not in READING for n, _ in steps[last_edit + 1:])
if ran:
    sys.exit(0)
print(hit.replace("\n", " ")[:40] + "|" + (steps[last_edit][1] or "")[-60:])
' 2>/dev/null || true)

if [ -n "${VERDICT:-}" ]; then
  m="${VERDICT%%|*}"; f="${VERDICT##*|}"
  jq -nc --arg m "$m" --arg f "$f" --arg g "$GATE_LINE" '{
    decision: "block",
    reason: ("🧭 Do not fabricate evidence. You wrote “" + $m + "” after editing `" + $f + "`, but there was NO run after the last edit in this turn (Bash / SQL / curl / MCP). Reading your own change is not a run. Which output are you claiming this from? → Run it (test, smoke, query, open the result) and give the verdict with its output — or write truthfully “edited, NOT verified”. Field incident: a script reported “fixed ✅” without a run stayed dead for 16 days. Bypass: BYPASS_KANT.\n" + $g)
  }'
  exit 0
fi

fi   # last non-empty
fi   # classes 1+2

# ===========================================================================
# Class 3 — DONE claim vs. the session edit/verify logs
# ===========================================================================
EDITS_LOG="/tmp/qg-edits-${sid}.log"
VERIFY_LOG="/tmp/qg-verify-${sid}.log"

# no edits log → nothing enforceable, allow
[ ! -s "$EDITS_LOG" ] && exit 0

# last assistant message WITH text, whole transcript
LAST_MSG=""
if [ -n "${tp:-}" ] && [ -f "$tp" ]; then
  LAST_MSG=$(TP="$tp" python3 -c "
import json, os
path = os.environ['TP']
last_text = ''
try:
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get('type') != 'assistant':
                continue
            msg = rec.get('message', {}) or {}
            content = msg.get('content', [])
            text_parts = []
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        text_parts.append(c.get('text', ''))
            elif isinstance(content, str):
                text_parts.append(content)
            if text_parts:
                last_text = '\n'.join(text_parts)
    print(last_text)
except Exception:
    pass
" 2>/dev/null || true)
fi

# tool-call-only turn (no claim) → allow
[ -z "$LAST_MSG" ] && exit 0

if grep -qE 'BYPASS_PTA' <<< "$LAST_MSG"; then
  exit 0
fi

LAST_LC=$(printf '%s' "$LAST_MSG" | tr '[:upper:]' '[:lower:]')

DONE_MATCH=0
if grep -qE '(\bdone\b|\bcompleted\b|\bdeployed\b|\bshipped\b|\bfixed\b|\bpatched\b|\bresolved\b|\bworks now\b|\bnow works\b|✅)' <<< "$LAST_LC"; then
  DONE_MATCH=1
fi

# negation guard: "not done" / "not yet" / "still failing" near the end → no claim
if grep -qE '(not done|not (yet )?complete|not yet|still failing|still broken|waiting for|still need)' <<< "$LAST_LC"; then
  if [ "$DONE_MATCH" = "1" ]; then
    TAIL=$(printf '%s' "$LAST_MSG" | tail -c 300 | tr '[:upper:]' '[:lower:]')
    if grep -qE '(not done|not yet|still failing|still broken|waiting for|still need|before deploy|before ack)' <<< "$TAIL"; then
      DONE_MATCH=0
    fi
  fi
fi

[ "$DONE_MATCH" = "0" ] && exit 0

# DONE claimed — compare the last edit with the last usable verify.
# verify log line: <ts>|Bash|<ok|fail>|<cwd>|<cmd>   or   <ts>|Skill|<skill>
T_EDIT=$(tail -n 1 "$EDITS_LOG" 2>/dev/null | cut -d'|' -f1)
LAST_EDIT_PATH=$(tail -n 1 "$EDITS_LOG" 2>/dev/null | cut -d'|' -f3-)
VERIFY_EVAL=$(VERIFY_LOG="$VERIFY_LOG" EDIT_PATH="$LAST_EDIT_PATH" python3 -c "
import os
log = os.environ.get('VERIFY_LOG', '')
edit = os.environ.get('EDIT_PATH', '') or ''
edit_dir, edit_base = os.path.dirname(edit), os.path.basename(edit)
best, reason = 0, 'none'
try:
    lines = open(log, encoding='utf-8', errors='replace').read().splitlines()
except Exception:
    lines = []
for ln in lines:
    f = ln.split('|')
    if len(f) < 3 or not f[0].isdigit():
        continue
    ts = int(f[0])
    if len(f) >= 5:
        status, vcwd, cmd = f[2], f[3], '|'.join(f[4:])
    else:
        status, vcwd, cmd = 'ok', '', '|'.join(f[2:])   # Skill line / 3-field line
    if status != 'ok':
        if ts > best:
            reason = 'failed'
        continue
    related = (not vcwd) or (edit_dir and (edit_dir + os.sep).startswith(vcwd.rstrip(os.sep) + os.sep)) \
              or (edit_base and edit_base in cmd) or (edit and edit in cmd)
    if not related:
        if ts > best:
            reason = 'unrelated'
        continue
    if ts > best:
        best, reason = ts, 'ok'
print(f'{best}|{reason}')
" 2>/dev/null || true)
T_VERIFY=$(printf '%s' "$VERIFY_EVAL" | cut -d'|' -f1)
V_REASON=$(printf '%s' "$VERIFY_EVAL" | cut -d'|' -f2)
[ -z "$T_VERIFY" ] && T_VERIFY=0
[ -z "$V_REASON" ] && V_REASON=none

case "$T_EDIT" in
  ''|*[!0-9]*) exit 0 ;;
esac
case "$T_VERIFY" in
  ''|*[!0-9]*) T_VERIFY=0 ;;
esac

# verify came after the last edit → allow
if [ "$T_VERIFY" -ge "$T_EDIT" ]; then
  exit 0
fi

fmt_ts() { # epoch → local time; portable (BSD date -r vs GNU date -d differ)
  python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(sys.argv[1]))))' "$1" 2>/dev/null || echo "$1"
}

EDIT_COUNT=$(wc -l < "$EDITS_LOG" 2>/dev/null | tr -d ' ')
if [ "$T_VERIFY" = "0" ]; then V_TIME="(none usable)"; else V_TIME=$(fmt_ts "$T_VERIFY"); fi

case "$V_REASON" in
  failed)    V_REASON_TXT="a verify RAN, but its output contained a failure — a failed test is not a verification" ;;
  unrelated) V_REASON_TXT="a verify ran in a different directory than the last edit and did not mention that file" ;;
  *)         V_REASON_TXT="no verify ran after the last edit" ;;
esac

cat <<EOF >&2
🔴 Evidence gate not satisfied — end of turn BLOCKED.

Your last message claims DONE, but the session has ${EDIT_COUNT} code edit(s) and no usable verify after the last one.

  Last edit:    $(fmt_ts "$T_EDIT") → ${LAST_EDIT_PATH}
  Last verify:  ${V_TIME}
  Reason:       ${V_REASON_TXT}

Fix (pick ONE):
  1. Run a post-task audit (the full Quality Gates pack ships one as the pta-gate skill)
  2. Run a real check via Bash: curl / tsc / npm test / pytest / python3 test_*.py / py_compile / bash -n / playwright / vitest / eslint
  3. Rewrite your last message so it makes no DONE claim (done / fixed / patched / works now)
  4. Failsafe: write BYPASS_PTA in your message (true false positive only)

Logs: ${EDITS_LOG} + ${VERIFY_LOG}
${GATE_LINE}
EOF

exit 2
