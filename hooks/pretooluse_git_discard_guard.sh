#!/usr/bin/env bash
# ============================================================================
# pretooluse_git_discard_guard.sh  ·  PreToolUse (matcher: Bash)
# ============================================================================
# WHAT:    Before `git checkout -- <paths>`, `git restore`, `git reset --hard` or
#          `git clean -f` runs, checks whether it would really throw away
#          UNCOMMITTED changes. If yes, it blocks (exit 2) and lists what would be
#          lost. On a clean tree it stays silent. Requires: bash, python3, git.
#
# WHY:     Field incident (09/2026): an agent working in a git worktree wrote a
#          test fixture into the MAIN checkout by mistake and then "tidied up"
#          with `git checkout -- <fixtures file>`. That discarded ~480 uncommitted
#          lines another session was still working on. No backup, no snapshot;
#          the work came back only by luck, from the other session's transcript.
#          An uncommitted change in a shared working tree is not always yours.
#
# BYPASS:  put the marker DISCARD_OK anywhere in the command, e.g.
#            git checkout -- a.txt   # DISCARD_OK
#
# DISABLE: touch $HOME/.claude/hooks/GIT_DISCARD_OFF
#
# TEST:    tests/test_pretooluse_git_discard_guard.sh
# ============================================================================

# Read stdin first, so the caller never gets SIGPIPE when we exit early.
INPUT=$(cat)

[ -f "$HOME/.claude/hooks/GIT_DISCARD_OFF" ] && exit 0

python3 - "$INPUT" <<'PY'
import json, os, re, subprocess, sys

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
if not cmd.strip() or "DISCARD_OK" in cmd:
    sys.exit(0)

base = d.get("cwd") or os.getcwd()


def segments(c):
    return [s.strip() for s in re.split(r"&&|\|\||;|\n", c) if s.strip()]


def git(root, *a, timeout=20):
    return subprocess.run(["git", "-C", root, *a], capture_output=True, text=True, timeout=timeout)


def resolve(cwd, p):
    p = os.path.expanduser(p.strip("'\""))
    return p if os.path.isabs(p) else os.path.join(cwd, p)


findings = []
cwd = base
for seg in segments(cmd):
    m = re.match(r"cd\s+(\S+)", seg)
    if m:                                   # `cd X && git ...` - follow the directory
        cwd = resolve(cwd, m.group(1))
        continue
    if not re.search(r"\bgit\b", seg):
        continue

    tok = seg.split()
    try:
        gi = tok.index("git")
    except ValueError:
        continue

    # global options before the verb: `git -C <dir>`, `git -c k=v`, `--no-pager` ...
    here = cwd
    rest = tok[gi + 1:]
    while rest and rest[0].startswith("-"):
        opt = rest.pop(0)
        if opt == "-C" and rest:
            here = resolve(here, rest.pop(0))
        elif opt.startswith("-C") and len(opt) > 2:
            here = resolve(here, opt[2:])
        elif opt == "-c" and rest:
            rest.pop(0)
    if not rest:
        continue
    verb = rest[0]
    args = rest[1:]

    hard = verb == "reset" and "--hard" in args
    clean = verb == "clean" and any(a.startswith("-") and "f" in a for a in args)
    # `git checkout` is destructive only with `--` or when an argument is an existing
    # path (otherwise it is a branch switch, which discards nothing).
    paths = []
    if verb in ("checkout", "restore"):
        if "--" in args:
            paths = args[args.index("--") + 1:]
        else:
            paths = [a for a in args if not a.startswith("-")
                     and os.path.exists(os.path.join(here, a))]
    if not (hard or clean or paths):
        continue

    try:
        r = git(here, "rev-parse", "--show-toplevel", timeout=10)
        if r.returncode != 0:
            continue
        root = r.stdout.strip()
        if hard:                            # reset --hard never touches untracked files
            st = git(root, "status", "--porcelain", "--untracked-files=no").stdout
        elif clean:
            st = git(root, "status", "--porcelain").stdout
        else:
            st = git(here, "status", "--porcelain", "--", *paths).stdout
    except Exception:
        continue

    lines = [l for l in st.splitlines() if l.strip()]
    if lines:
        findings.append((root, seg[:100], lines))

if findings:
    blocks = []
    for root, seg, lines in findings:
        listing = "\n".join("      " + l for l in lines[:15])
        more = f"\n      ... and {len(lines) - 15} more" if len(lines) > 15 else ""
        blocks.append(f"  repo:    {root}\n  command: {seg}\n  would discard:\n{listing}{more}")
    sys.stderr.write(
        "BLOCKED - this would discard UNCOMMITTED changes\n\n"
        + "\n\n".join(blocks) +
        "\n\nWHY: an uncommitted change in a shared working tree is not necessarily yours.\n"
        "In a field incident (09/2026) a \"cleanup\" `git checkout -- <file>` wiped ~480 lines\n"
        "another session was still working on. Git could not bring them back.\n\n"
        "WHAT TO DO:\n"
        "  1. LOOK at what is there:   git -C <repo> diff -- <paths>\n"
        "  2. Not yours? Leave it alone and make your change in your own worktree/branch.\n"
        "  3. Really meant to discard it? Save a copy first:\n"
        "       git -C <repo> diff -- <paths> > /tmp/discarded.patch\n"
        "  4. Deliberate discard: add the marker DISCARD_OK to the command.\n\n"
        "Disable: touch $HOME/.claude/hooks/GIT_DISCARD_OFF\n"
        "Gate: Wizalnut Quality Gates · pretooluse_git_discard_guard.sh\n")
    sys.exit(2)
PY
# python's exit code is the gate's decision (2 = block) - pass it through
exit $?
