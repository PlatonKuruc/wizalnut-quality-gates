#!/usr/bin/env bash
# ============================================================================
# pretooluse_secret_expansion_guard.sh  ·  PreToolUse (matcher: Bash)
# ============================================================================
# WHAT:    Blocks a command that would PRINT the value of a secret shell variable
#          to stdout (and so into the session transcript): echo/printf/print of
#          $VAR or ${VAR...}, `printenv VAR`, `env | grep VAR`, `set | grep VAR`,
#          `${VAR:-default}`, where VAR looks like
#          KEY|TOKEN|SECRET|PASS|PASSWORD|APIKEY|AUTH|BEARER|CREDENTIAL.
#          Lets through checks that print nothing secret: `[ -n "$MY_API_KEY" ]`,
#          `${MY_API_KEY:+set}`, `test -n`, `: "${MY_API_KEY:?}"`, length or hash
#          only (`${#MY_API_KEY}`, `| wc -c`, `| shasum`, `| cut -c1-4`,
#          `| sed 's/./*/g'`), and output sent to /dev/null. Requires: bash, python3.
#
# WHY:     Field incident (08/2026): `echo ${MY_API_KEY:-MISSING}` printed a full
#          API key into the transcript. Five other secret hooks stayed silent,
#          because they scan for LITERAL key shapes (sk-..., eyJ...), not for a
#          shell variable being EXPANDED at run time.
#
# BYPASS:  SECRET_PRINT_OK anywhere in the command (deliberate, your own risk).
#
# DISABLE: touch $HOME/.claude/hooks/SECRET_EXPANSION_GUARD_OFF
#
# TEST:    tests/test_pretooluse_secret_expansion_guard.sh
# ============================================================================
set -uo pipefail
INPUT=$(cat)

[ -f "$HOME/.claude/hooks/SECRET_EXPANSION_GUARD_OFF" ] && exit 0

RES=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, re
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if d.get("tool_name") != "Bash": sys.exit(0)
c = (d.get("tool_input") or {}).get("command") or ""
if "SECRET_PRINT_OK" in c: sys.exit(0)
V = r"[A-Za-z_0-9]*(KEY|TOKEN|SECRET|PASS|PASSWORD|APIKEY|AUTH|BEARER|CREDENTIAL)[A-Za-z_0-9]*"
# safe shapes -> let through
SAFE = [r"\$\{#\s*" + V + r"\}", r"\$\{" + V + r":\+", r"\$\{" + V + r":\?", r"\[\s*-[nz]\s+\"?\$\{?" + V, r"test\s+-[nz]\s+\"?\$\{?" + V,
        r"\|\s*(wc|shasum|sha256sum|md5|cut -c|sed .s/\./\*)", r">\s*/dev/null"]
# dangerous shapes -> the value gets printed
DANGER = [r"\b(echo|printf|print)\b[^|;\n]*\$\{?" + V, r"\bprintenv\s+" + V, r"\b(env|set|export -p)\b[^|\n]*\|\s*grep[^|\n]*(KEY|TOKEN|SECRET|PASS)",
          r"\$\{" + V + r":-[^}]*\}"]
hit = next((m.group(0) for p in DANGER for m in [re.search(p, c)] if m), None)
if not hit: sys.exit(0)
if any(re.search(p, c) for p in SAFE): sys.exit(0)
print(hit[:80])
' 2>/dev/null)
[ -z "$RES" ] && exit 0

{
  printf '%s\n' "BLOCKED - this command would PRINT the value of a secret variable into the transcript"
  printf '   match: %s\n' "$RES"
  cat <<'EOF'

The transcript is a file on disk that gets stored, summarized and shared - a key
printed into it is a leaked key. Field incident 08/2026: `echo ${MY_API_KEY:-MISSING}`
printed a full key while every literal-pattern secret scanner stayed silent.

INSTEAD:
  exists?        [ -n "$MY_API_KEY" ] && echo set || echo missing
  length/prefix: echo "${#MY_API_KEY} chars, prefix $(printf %s "$MY_API_KEY" | cut -c1-4)..."
  use it:        pass it straight to the tool (curl -H "Authorization: Bearer $MY_API_KEY" ...)
                 without echoing it first.

Bypass (deliberate, your own risk): add SECRET_PRINT_OK to the command.
Disable: touch $HOME/.claude/hooks/SECRET_EXPANSION_GUARD_OFF
Gate: Wizalnut Quality Gates · pretooluse_secret_expansion_guard.sh
EOF
} >&2
exit 2
