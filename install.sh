#!/usr/bin/env bash
# ============================================================================
# Wizalnut Quality Gates — Free Starter (3 gates) — installer / uninstaller
# The same installer as the full pack. Upgrading: run the full pack's install.sh
# on top of this one; it keeps one registration per gate.
# ============================================================================
# Copies the gates into your Claude Code home and registers them in
# settings.json. Idempotent: run it twice, nothing doubles.
#
#   bash install.sh                    # install into ~/.claude
#   bash install.sh --home /path       # install into another Claude home
#   bash install.sh --dry-run          # show what would change, touch nothing
#   bash install.sh --no-settings      # copy files only, do not edit settings.json
#   bash install.sh --uninstall        # remove hooks + registrations (skills stay
#                                      #   unless you add --remove-skills)
#
# What it touches:
#   $CLAUDE_HOME/hooks/<gate>.sh|.py          the gates (and their python bodies)
#   $CLAUDE_HOME/hooks/tests/test_<gate>.sh   one canary test per gate (+ run_tests.sh)
#   $CLAUDE_HOME/bin/brief_check.py           brief checker used by the brief-loop gate
#   $CLAUDE_HOME/skills/<name>/               skills, if the pack has any (this one has none)
#   $CLAUDE_HOME/settings.json                hook registrations (backup written first)
#   $CLAUDE_HOME/quality-gates.manifest       list of files this installer owns
#
# Requirements: bash, python3, jq. macOS ships bash 3.2 — that is fine.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
DRY=0; DO_SETTINGS=1; UNINSTALL=0; REMOVE_SKILLS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) CLAUDE_HOME="$2"; shift 2 ;;
    --home=*) CLAUDE_HOME="${1#--home=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --no-settings) DO_SETTINGS=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --remove-skills) REMOVE_SKILLS=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

for dep in python3 jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "missing dependency: $dep (macOS: brew install $dep · Debian/Ubuntu: apt install $dep)" >&2
    exit 1
  fi
done

MANIFEST="$CLAUDE_HOME/quality-gates.manifest"
SETTINGS="$CLAUDE_HOME/settings.json"
say() { printf '%s\n' "$*"; }
act() { if [ "$DRY" = 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# settings.json merge — done in python so the JSON survives intact
# ---------------------------------------------------------------------------
merge_settings() {  # $1 = add|remove
  python3 - "$1" "$SETTINGS" "$CLAUDE_HOME" "$HERE" "$DRY" <<'PY'
import glob, json, os, shutil, sys, time
mode, settings, home, here, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
entries = []
for reg in sorted(glob.glob(os.path.join(here, "hooks", "registry*.json"))):
    with open(reg, encoding="utf-8") as fh:
        entries += json.load(fh)
if not entries:
    print("  no registry*.json found in pack/hooks — nothing to register"); sys.exit(0)
try:
    with open(settings, encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    print(f"  settings.json is not valid JSON ({e}); refusing to touch it"); sys.exit(1)
hooks = data.setdefault("hooks", {})
changed = 0
def cmd_for(f):
    p = os.path.join(home, "hooks", f)
    return f'bash "{p}"' if " " in p else f"bash {p}"
def base(h):
    c = (h.get("command") or "").strip().rstrip('"')
    return os.path.basename(c.split()[-1].strip('"')) if c else ""
for e in entries:
    ev, matcher, f = e["event"], e.get("matcher") or "", e["file"]
    groups = hooks.setdefault(ev, [])
    if mode == "add":
        group = next((g for g in groups if (g.get("matcher") or "") == matcher), None)
        if group is None:
            group = {"matcher": matcher, "hooks": []}
            groups.append(group)
        if any(base(h) == f for h in group["hooks"]):
            continue
        h = {"type": "command", "command": cmd_for(f)}
        if e.get("timeout"):
            h["timeout"] = e["timeout"]
        group["hooks"].append(h); changed += 1
    else:
        for g in groups:
            before = len(g.get("hooks", []))
            g["hooks"] = [h for h in g.get("hooks", []) if base(h) != f]
            changed += before - len(g["hooks"])
        hooks[ev] = [g for g in groups if g.get("hooks")]
        if not hooks[ev]:
            del hooks[ev]
if not changed:
    print(f"  settings.json: nothing to {mode} (already in the wanted state)"); sys.exit(0)
if dry:
    print(f"  [dry-run] settings.json: would {mode} {changed} registration(s)"); sys.exit(0)
os.makedirs(os.path.dirname(settings), exist_ok=True)
if os.path.exists(settings):
    bak = settings + ".bak-quality-gates-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(settings, bak); print(f"  backup: {bak}")
with open(settings, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False); fh.write("\n")
print(f"  settings.json: {'added' if mode == 'add' else 'removed'} {changed} registration(s)")
PY
}

# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  say "Wizalnut Quality Gates Free — uninstall from $CLAUDE_HOME"
  # The full pack shares the manifest. If it was installed on top of this one,
  # uninstalling here would delete its files but leave its registrations, so stop.
  if [ -f "$MANIFEST" ]; then
    foreign=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b="$(basename "$f")"
      if [ ! -e "$HERE/hooks/$b" ] && [ ! -e "$HERE/hooks/tests/$b" ] && [ ! -e "$HERE/bin/$b" ] && [ ! -d "$HERE/skills/$b" ]; then
        foreign="$f"; break
      fi
    done < "$MANIFEST"
    if [ -n "$foreign" ]; then
      echo "The full Quality Gates pack is installed on top of this one ($foreign)." >&2
      echo "Uninstall with the full pack instead: bash install.sh --uninstall from its folder." >&2
      exit 1
    fi
  fi
  [ "$DO_SETTINGS" = 1 ] && merge_settings remove
  if [ -f "$MANIFEST" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        */skills/*) [ "$REMOVE_SKILLS" = 1 ] || continue ;;
      esac
      [ -e "$f" ] && act rm -rf "$f"
      case "$f" in
        *.py) b="$(basename "${f%.py}")"; d="$(dirname "$f")/__pycache__"
              for pyc in "$d/$b".*.pyc; do [ -e "$pyc" ] && act rm -f "$pyc"; done
              [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ] && act rmdir "$d" ;;
      esac
    done < "$MANIFEST"
    act rm -f "$MANIFEST"
  else
    say "  no manifest at $MANIFEST — removing by name from the pack listing"
    for f in "$HERE"/hooks/*.sh "$HERE"/hooks/*.py; do
      [ -e "$f" ] && act rm -f "$CLAUDE_HOME/hooks/$(basename "$f")"
    done
    for f in "$HERE"/hooks/tests/*.sh; do
      [ -e "$f" ] && act rm -f "$CLAUDE_HOME/hooks/tests/$(basename "$f")"
    done
    act rm -f "$CLAUDE_HOME/bin/brief_check.py"
  fi
  say "done. Skills were $([ "$REMOVE_SKILLS" = 1 ] && echo removed || echo kept) (use --remove-skills to delete them)."
  exit 0
fi

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
say "Wizalnut Quality Gates Free — install into $CLAUDE_HOME"
act mkdir -p "$CLAUDE_HOME/hooks/tests" "$CLAUDE_HOME/bin" "$CLAUDE_HOME/skills" "$CLAUDE_HOME/logs"
OWNED=()

n=0
for f in "$HERE"/hooks/*.sh "$HERE"/hooks/*.py; do
  [ -e "$f" ] || continue
  dst="$CLAUDE_HOME/hooks/$(basename "$f")"
  act cp "$f" "$dst"; act chmod +x "$dst"; OWNED+=("$dst"); n=$((n+1))
done
say "  hooks: $n file(s)"

n=0
for f in "$HERE"/hooks/tests/*.sh; do
  [ -e "$f" ] || continue
  dst="$CLAUDE_HOME/hooks/tests/$(basename "$f")"
  act cp "$f" "$dst"; act chmod +x "$dst"; OWNED+=("$dst"); n=$((n+1))
done
say "  tests: $n file(s)"

if [ -f "$HERE/bin/brief_check.py" ]; then
  act cp "$HERE/bin/brief_check.py" "$CLAUDE_HOME/bin/brief_check.py"
  act chmod +x "$CLAUDE_HOME/bin/brief_check.py"; OWNED+=("$CLAUDE_HOME/bin/brief_check.py")
  say "  bin: brief_check.py"
fi

n=0; skipped=""
for d in "$HERE"/skills/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  dst="$CLAUDE_HOME/skills/$name"
  if [ -e "$dst" ]; then skipped="$skipped $name"; continue; fi
  act cp -R "$d" "$dst"; OWNED+=("$dst"); n=$((n+1))
done
say "  skills: $n installed${skipped:+ · kept yours (not overwritten):$skipped}"

if [ "$DRY" = 0 ]; then
  # merge with the previous manifest: a re-install must not forget files it
  # installed last time (e.g. skills it now skips because they already exist)
  {
    [ -f "$MANIFEST" ] && cat "$MANIFEST"
    for f in "${OWNED[@]}"; do printf '%s\n' "$f"; done
  } | awk 'NF && !seen[$0]++' > "$MANIFEST.tmp"
  : > "$MANIFEST"
  while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f" >> "$MANIFEST"; done < "$MANIFEST.tmp"
  rm -f "$MANIFEST.tmp"
  say "  manifest: $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') entries)"
fi

[ "$DO_SETTINGS" = 1 ] && merge_settings add

say ""
say "Next: run the canary tests —  QG_HOOKS_DIR=$CLAUDE_HOME/hooks bash $CLAUDE_HOME/hooks/tests/run_tests.sh"
say "Then start a new Claude Code session; hooks load at session start."
exit 0
