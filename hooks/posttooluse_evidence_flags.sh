#!/usr/bin/env bash
# ============================================================================
# posttooluse_evidence_flags.sh — PostToolUse flag setter (never blocks)
# ============================================================================
# WHAT:    Logs every code edit and every verify run (test / lint / build /
#          syntax check / curl, or a verification skill) together with its
#          result, so stop_no_fabricated_evidence.sh (class 3) can tell whether
#          the last edit was ever verified. Always exit 0.
# WHY:     Field incident, 08/2026: a whitelisted test command that ran after an
#          edit counted as "verified" although its output was a failure. Since
#          then a verify is logged with its RESULT (read from the output — the
#          PostToolUse payload has no exit code) plus its working directory, and
#          the stop hook only accepts ok runs related to the edited file.
# BYPASS:  add "# pta-verified" or BYPASS_PTA to a Bash command to have it
#          logged as a verify run (its result is still read from the output).
# DISABLE: touch $HOME/.claude/hooks/EVIDENCE_FLAGS_OFF
# TEST:    $HOME/.claude/hooks/tests/test_posttooluse_evidence_flags.sh
#
# Logs (one line per event, shared with the stop hook):
#   /tmp/qg-edits-<sid>.log   <ts>|<tool>|<file_path>            Edit/Write/MultiEdit/NotebookEdit
#   /tmp/qg-verify-<sid>.log  <ts>|Bash|<ok|fail>|<cwd>|<cmd>    Bash verify command
#                             <ts>|Skill|<skill>                 verification skill
# Only code extensions count as edits; docs (.md/.txt), temp files and
# scratchpad files are ignored. Verification skills that earn credit:
# pta-gate, senior-review, wald-principle, inversion (skills of the full pack).
# Matcher: Bash|Edit|Write|MultiEdit|NotebookEdit|Skill. Requires: python3.
# ============================================================================
set -uo pipefail
[ -f "$HOME/.claude/hooks/EVIDENCE_FLAGS_OFF" ] && exit 0
INPUT=$(cat)

printf '%s' "$INPUT" | python3 -c '
import json, re, sys, time

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = d.get("tool_name", "") or ""
sid = d.get("session_id", "unknown") or "unknown"
inp = d.get("tool_input", {}) or {}
ts = int(time.time())

def append(path, line):
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# EDIT flag — Edit / Write / MultiEdit / NotebookEdit
# ---------------------------------------------------------------------------
if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    fp = inp.get("file_path", "") or ""
    if "/scratchpad/" in fp or fp.startswith(("/tmp/", "/private/tmp/")):
        sys.exit(0)   # throwaway files do not create a verify obligation
    # code extensions only; docs and unknown extensions are skipped (no false positives on configs)
    if not re.search(r"\.(ts|tsx|js|jsx|mjs|cjs|py|sql|sh|bash|html|css|json|yaml|yml|go|rs|rb|java|kt|swift|c|cpp|h)$", fp):
        sys.exit(0)
    append(f"/tmp/qg-edits-{sid}.log", f"{ts}|{tool}|{fp}")
    sys.exit(0)

# ---------------------------------------------------------------------------
# SKILL flag — a verification skill earns verify credit
# ---------------------------------------------------------------------------
if tool == "Skill":
    skill = inp.get("skill", "") or ""
    if skill in ("pta-gate", "senior-review", "wald-principle", "inversion"):
        append(f"/tmp/qg-verify-{sid}.log", f"{ts}|Skill|{skill}")
    sys.exit(0)

if tool != "Bash":
    sys.exit(0)

cmd = inp.get("command", "") or ""
if not cmd:
    sys.exit(0)

# ---------------------------------------------------------------------------
# VERIFY flag — is this Bash command a verify run?
# ---------------------------------------------------------------------------
lc = cmd.lower()
verified = False
needles = [
    "curl ", "npm test", "npm run test", "yarn test", "pnpm test",
    "npm run build", "yarn build", "pnpm build", "vercel dev", "vercel build",
    "vitest", "jest", "playwright", "cypress", "pytest", "python -m pytest",
    "python -m unittest", "python3 -m pytest", "python3 -m unittest",
    "go test", "cargo test", "mvn test", "gradle test",
    "deno test", "bun test", "eslint", "npm run lint", "yarn lint", "pnpm lint",
    "mypy", "ruff", "pyright",
    "bash -n", "sh -n", "zsh -n", "shellcheck",
    "ffprobe",
    "python -m py_compile", "python3 -m py_compile",
]
if any(n in lc for n in needles):
    verified = True
elif re.search(r"\bpython3?\s+(?:\S+/)?[\w.]*test[\w.]*\.py\b", lc):
    verified = True   # running a test file directly
elif re.search(r"\btsc\b", lc):
    verified = True
elif re.search(r"BYPASS_PTA|#\s*pta-verified", cmd):
    verified = True
if not verified:
    sys.exit(0)

# --- result of the run (no exit code in the payload, read it from the output) ---
tr = d.get("tool_response") or {}
blob = ""
interrupted = False
if isinstance(tr, dict):
    blob = (str(tr.get("stdout") or "") + chr(10) + str(tr.get("stderr") or ""))
    interrupted = bool(tr.get("interrupted"))

FAIL_SIGNALS = [
    "traceback (most recent call last)",
    "no such file or directory",
    "command not found",
    "syntax error",
    "assertionerror",
    "modulenotfounderror",
    "importerror",
    "segmentation fault",
    "connection refused",
    "could not resolve host",
]
low = blob.lower()
status = "ok"
if interrupted:
    status = "fail"
elif any(sig in low for sig in FAIL_SIGNALS):
    status = "fail"
elif re.search(r"(^|[^a-z])(failed|fail:)([^a-z]|$)", low) \
     or re.search(r"^error:", low, re.M) \
     or chr(10008) in blob:
    status = "fail"   # standalone tokens only — "failover" / "error_handler" in a path do not count

cwd = (d.get("cwd") or "").replace("|", "_")
short = " ".join(cmd.split())[:200].replace("|", "_")
append(f"/tmp/qg-verify-{sid}.log", f"{ts}|Bash|{status}|{cwd}|{short}")
' 2>/dev/null

exit 0
