# Quick start: let your LLM agent play

df-llm-helper v2 runs a kernel inside DFHack that defends and supplies the fort; your agent plans the year and
answers the few events that need judgement. This page has the prompt to paste, what each step should print, and
what to do when a step fails. Background: `README.md`; the agent's rules: `RULES.md`.

## What you need
- Dwarf Fortress 53.x from Steam with DFHack (tested: DF 53.16 + DFHack 53.16-r2) on Windows (tested: Windows 11).
- Git, Python 3.11+ (standard library only), Git Bash for the hook.
- An LLM agent that runs shell commands on the same PC. Built for Claude Code; any agent works that can keep
  one process (`follow`) running and read its output lines.
- Best: clone first (`git clone https://github.com/GordonMohrin/df-llm-helper`) and start Claude Code
  inside that folder. Only then does its fair-play hook (`.claude/settings.json`) check every shell command.

## The prompt
Close DF, then paste this into the agent:

```text
Play Dwarf Fortress for me with df-llm-helper. DF 53.x (Steam) + DFHack are installed on this Windows PC.
1. git clone https://github.com/GordonMohrin/df-llm-helper, work in that folder, read RULES.md and follow it.
2. Find my DF folder (it has hack/dfhack-run.exe) and set DFLLM_DF to it. With DF closed run
   python tools/migrate_v2.py (dry run), then python tools/migrate_v2.py --apply.
3. Ask me to start DF through DFHack and to load or embark a fort. In it run dfllm adopt, then dfllm selftest full
   (via dfhack-run).
4. Keep python -m df_llm_helper follow running as your watcher. Make the year plan (plan propose, check, apply)
   and react to its wake lines as RULES.md says. Fair play only; report briefly; ask me only for real decisions.
```

## What each step should print
`<DF>` is your DF folder; `dfhack-run` is `"<DF>/hack/dfhack-run.exe"` (quote it: the path has spaces).

| Step | Command | Good result |
|---|---|---|
| 2 | `ls "<DF>/hack/dfhack-run.exe"` | the file exists |
| 2 | `python tools/migrate_v2.py` | a numbered step list; `script-paths` and `onmapload-init` are `todo` on a fresh install, the rest `done` or `n/a` |
| 2 | `python tools/migrate_v2.py --apply` | `-> ok` for both; `summary: ... applied` |
| 2 (optional) | `python -m df_llm_helper lint` | `0 finding(s)` |
| 3 (optional) | `dfhack-run dfllm selftest --mock` | `dfllm selftest: 1 pass, 0 fail` |
| 3 | `dfhack-run dfllm adopt` | `dfllm: ...` with no error; then `dfhack-run dfllm status` lists 17 modules, none `DISABLED` |
| 3 | `dfhack-run dfllm selftest full` | `0 fail` |
| 4 | `python -m df_llm_helper status` | `<save> y<year> <season> d<day> PEACE ... P0 ...` and a `kern ... ms/s` line |
| 4 | `python -m df_llm_helper follow` | nothing for a while: it prints only class-A events, at most 6 lines per hour, e.g. `WAKE y281 spr d12 PEACE \| PLAN_EXHAUSTED: ... \| next: ...` |
| 4 | `python -m df_llm_helper plan propose y1.json`, edit, `plan check y1.json`, `plan apply y1.json` | `check`: `plan OK: ...`; `apply`: `plan.json y<year> + <n> bp ...; ok <id> plan.reload: ...` (the kernel's reply) |

Keep plan drafts outside `<DF>/dfllm-runtime/`: the hook refuses file edits there (only `dfllm` commands and the
kernel write that folder). Without a file argument, `plan propose` writes `<save>/plan.draft.json`, which can be
applied unchanged.

## A new fort
- **By hand (simplest):** create a world, pick a site with trees, flowing water and no aquifer, embark (Play now or
  Prepare carefully), and tell the agent the fort is loaded.
- **With the helper (experimental):** `python tools/embark/embark.py newgame --world <ASCII part of the world name>`,
  `scan WX,WY ...` (ranks sites from the vanilla embark panel, embarks nowhere), then
  `embark WX,WY --play-now`. Prepare carefully cannot be driven yet; `--play-now` takes DF's default seven.
  It needs `[EMBARK_WARNING_ALWAYS:YES]` in DF's `prefs/d_init.txt` (Settings: confirmation window for all embarks);
  the tools only read prefs. Procedure and fair-play limits: `tools/embark/README.md`.
- An existing fort works too: load it and `adopt` it. `adopt` is once per fort and cannot be undone in game; the
  kernel then manages that save on every load.

## Troubleshooting
**DF is not running through DFHack.** `dfhack-run` prints a connection error, or `hack/dfhack-run.exe` does not exist.
Install DFHack (Steam: the DFHack app) and start DF through it from the Steam library. `dfhack-run help` must answer
before anything else works. DF must be fully started (title screen or a loaded fort).

**`dfllm` is not a recognized command (script-paths).** DFHack cannot find `lua/dfllm.lua`:
- `<DF>/dfhack-config/script-paths.txt` must hold one line `+<your clone>\lua`. Run `python tools/migrate_v2.py`
  (dry run) to see whether `script-paths` is `done`.
- DF reads that file only at startup: after `--apply`, restart DF (through DFHack).
- Moved or re-cloned the repo? Run the migration again and remove the stale line by hand, so only one clone is on the
  path.

**`migrate_v2.py --apply` says REFUSED.** DF is running (or its state is unknown). Close DF and run it again.

**Your own `onMapLoad.init` lines are gone.** The migration makes that file run only `dfllm boot`; the original is in
`<DF>/_archive-v1/migrate_v2/onMapLoad.init.<time>.orig`. Copy your lines back below `dfllm boot`.

**Python commands find no save or the wrong folder** (`dfllm: ...` no save). `DFLLM_DF` is not set in that shell, so
the tools look in the author's Steam path. Set it, or pass `--df "<DF>"` before the command
(`python -m df_llm_helper --df "<DF>" status`). The runtime folder is `<DF>/dfllm-runtime/<save>/`; it appears after
`adopt`.

**`adopt` or `boot` reports an error, or `status` shows a module `DISABLED`.** Read
`<DF>/dfllm-runtime/<save>/kern.log`. A module that faults is backed off and re-enabled by itself; the agent writes a
note (RULES.md §7 KERN_FAULT) instead of patching the game.

**The game stays paused.** The kernel never releases a pause by you or by DF (a save loads paused). Unpause in DF
yourself. After 10 minutes paused the agent gets a `DECISION_NEEDED pause` wake line to remind you.

**The hook blocks a command.** It prints the reason (for example `inline lua is not allowed`). The agent must use a
`dfllm` command or `python -m df_llm_helper cmd <verb>` instead and never work around the hook. If nothing is ever
blocked, check that the agent session started inside the clone (`.claude/settings.json`).

**`follow` prints nothing for a long time.** Normal in peace. `python -m df_llm_helper status` and `doctor` show the
fort and the speed at any time. A `heartbeat` older than 120 s in `status` means the kernel is not running: check
that DF runs, the fort is loaded, then `dfhack-run dfllm status`.

## Desktop and focus
- The kernel runs inside DF's frame callback; the agent never needs DF's window or keyboard focus. DF may run on
  another virtual desktop (the author's runs used a hidden desktop) or behind other windows. Keep the PC awake: if
  Windows sleeps, the game stops.
- `tools/win/start_df_desktop1.ps1` starts DF through Steam and moves its window to virtual desktop 1 without taking
  focus (on the author's install DFHack loads with DF; check with `dfhack-run help`). It is optional.
- The embark helper simulates input inside DF, so it also works unfocused. Do not click or type in DF while it runs.
- You can watch and play along in DF at any time. Prefer pausing over issuing your own orders during a siege.

## How to stop
1. **Stop the agent:** stop the `follow` process (the Monitor, or Ctrl+C) and end the session. The kernel keeps the
   fort running: defense, supply and the approved plan; it never starts a new ★ phase by itself.
2. **Pause** in DF whenever you like (space). Nothing in v2 unpauses your pause.
3. **Stop the kernel** for this game session: `dfhack-run dfllm stop`. It restores the runtime settings (timestream,
   fps, autosave, overlays, pop cap). The next load of an adopted save boots it again; `dfhack-run dfllm boot`
   starts it now. If settings look wrong after a crash or unload: `dfhack-run dfllm restore` (restoring on a real
   unload is not live-tested yet).
4. **Remove v2 from DF:** close DF, then `python tools/migrate_v2.py --revert` (restores `script-paths.txt` and
   `onMapLoad.init`). Adopted saves keep their marker, but nothing boots the kernel any more. You may delete
   `<DF>/dfllm-runtime/` afterwards.
