# Quality Gates for Claude Code — free starter

Three hooks that stop your agent from saying "fixed" when it never ran anything, from throwing away your uncommitted work, and from printing an API key into the transcript.

They run **at the moment of action**, deterministically, with no model in the loop. Exit code 2 blocks the action and tells the agent why.

```
> fix the failing login test
⏺ Fixed. The login test works now.

BLOCKED.
You wrote "works now" after editing auth.py, but there was NO run
after the last edit in this turn. Reading your own change is not a run.
Which output are you claiming this from?
                            Gate: stop_no_fabricated_evidence
```

That is a real block, not a mockup.

## What the three gates stop

| Gate | Files | What it stops |
|---|---|---|
| **Done gate** | `stop_no_fabricated_evidence.sh` + `posttooluse_evidence_flags.sh` (install both) | The agent ends a turn with "fixed", "works now" or "done" after a code edit it never ran. It also refuses words of approval put in your mouth ("just like you wanted"). |
| **Git discard guard** | `pretooluse_git_discard_guard.sh` | `git checkout -- <path>`, `git restore`, `git reset --hard`, `git clean -f` when they would throw away uncommitted changes. Shows what would vanish. A clean tree passes silently. |
| **Secret expansion guard** | `pretooluse_secret_expansion_guard.sh` | `echo $API_KEY`, `printenv TOKEN`, `env \| grep SECRET`, `${KEY:-default}`: anything that would print a secret variable's value into the transcript. Length and prefix checks pass. |

Each gate ships with a canary test and a kill switch: `mkdir -p ~/.claude/hooks && touch ~/.claude/hooks/<NAME>_OFF`, with the name in each hook's header (for example `SECRET_EXPANSION_GUARD_OFF`). Installed as a plugin, all three switch off at once with `claude plugin disable wizalnut-quality-gates@wizalnut`.

Requirements: Claude Code 2.x, bash (macOS 3.2 is fine), python3, jq, git.

## Install as a plugin

```bash
claude plugin marketplace add PlatonKuruc/wizalnut-quality-gates
claude plugin install wizalnut-quality-gates@wizalnut
```

Or from inside a session: `/plugin marketplace add PlatonKuruc/wizalnut-quality-gates`, then `/plugin install wizalnut-quality-gates@wizalnut`. Start a new session afterwards; hooks load at session start. `claude plugin update wizalnut-quality-gates@wizalnut` gets the next version, `claude plugin uninstall wizalnut-quality-gates@wizalnut` removes it. Your `settings.json` is not touched.

## Or install with the script

```bash
git clone https://github.com/PlatonKuruc/wizalnut-quality-gates.git
cd wizalnut-quality-gates
bash install.sh --dry-run       # shows every change first
bash install.sh                 # into ~/.claude, backs up settings.json first
QG_HOOKS_DIR=~/.claude/hooks bash ~/.claude/hooks/tests/run_tests.sh
```

Start a new Claude Code session afterwards; hooks load at session start.

Uninstall: `bash install.sh --uninstall`. A dated backup of `settings.json` is written before every change. The script needs `jq`; the plugin does not.

Pick one way, not both: the plugin and the script together register every gate twice.

## See one fire in your own terminal

A hook reads one JSON event on stdin. Exit code 2 is what tells Claude Code to stop. From the cloned folder:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"echo $DEMO_API_KEY"}}' \
  | bash hooks/pretooluse_secret_expansion_guard.sh; echo "exit $?"
```

You get `BLOCKED - this command would PRINT the value of a secret variable` and `exit 2`.

## Why gates and not instructions

Every one of these started as a sentence in a memory file or in `CLAUDE.md`. The agent read the sentence and did the thing anyway, because at the moment of action the sentence was not in front of it. A hook runs at that exact moment, every time.

A gate that fires wrongly is one line to bypass and one line to disable. Disable it rather than fight it — and tell us what it caught wrongly.

## Where these come from

We run a video and automation studio on Claude Code: 130+ hooks, dozens of parallel sessions a day. Each gate exists because the mistake it stops cost us real work — a script that reported "fixed ✅" without a run and stayed dead for 16 days, a `git checkout` over another session's uncommitted changes, a key echoed into a transcript that lives on disk.

These three are the starter. The full pack is 16 gates and 6 skills: premise checks before the first edit, a brief checker for subagent prompts, a HEAD check before `commit --amend` and force-push, guards on `bash -x` over scripts that read keys, shell traps (`| grep -q` under `pipefail`, GNU `timeout` on macOS), conversation gates (vague prompts, three corrections in a row, "it doesn't work" without reading the logs), and the skills we audit our own work with — colombo, pta-gate, wald-principle, inversion, senior-review, brief-loop.

→ **[wizalnut.com/en/packs](https://wizalnut.com/en/packs)** — €29. Same installer; run it on top of the script install and it keeps one registration per gate. If you installed the plugin, uninstall it first.

## License

MIT. Use them, fork them, ship them in your own setup. The full pack is a separate, paid product.

---
[Wizalnut](https://wizalnut.com) · a trade name of Epic production s.r.o.
