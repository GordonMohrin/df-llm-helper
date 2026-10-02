# BUG-112: with the default Windows console encoding (cp1252) any output containing a character outside cp1252 (e.g. `☼`) aborts the command; `wake` has already consumed the events

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `df_llm_helper/cli.py:1193-1214` (`main`: no stdout configuration; `UnicodeEncodeError` is a `ValueError` -> `Error: 'charmap' codec ...`, exit 2), `df_llm_helper/wake.py:99-111` (state is stored before the lines are printed), `cli.py:268-280` (`cmd_wake`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro 10.0.26200 (German locale), Python 3.14.3, Git Bash; `sys.stdout.encoding` = `cp1252` when `PYTHONUTF8`/`PYTHONIOENCODING` are **not** set (the tester's shell had them set; the task instructions mention them, MANUAL/README do not)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-112/repro.py        # runs the commands with PYTHONUTF8/PYTHONIOENCODING removed
```

## Expected
Output never crashes on a character the game itself produces: Dwarf Fortress names artifacts `☼bronze figurine of goblins☼` (the live `events.log` has such lines, plus the mojibake `├«ton` from the old watcher, see BUG-116).
`wake` must not lose events because the console cannot print them.

## Actual
```
$ overlay "Test ☼ ok"                    ->  Error: 'charmap' codec can't encode character '☼' in position 23   [exit 2]
$ wake   (2 new CRITICAL lines, one with ☼)   ->  Error: 'charmap' codec can't encode character '☼' in position 69   [exit 2]
$ wake   (next run)                      ->  (nothing)  <- both events, incl. "CITIZEN_DEATH Mebzuth has been found dead", are lost
$ plan trade --json t.json               ->  half of the output, then Error: 'charmap' ...
```
With `PYTHONUTF8=1` the same wake prints `WAKE critical [MASTERPIECE_CRAFTED]: Urist has created a masterpiece ☼goblin figurine☼!`.
`wake_check()` stores `seen`/`events_n` before the lines are printed, so a print error loses the events for good - in the live game a death or ambush line. Other commands (`digest` with unit names from the game: `Ezrûamxu`, `ïtebmeban` are cp1252-safe, but Dwarven names with `☼`/box characters are not) can fail the same way.

## Evidence
`Bugs/evidence/BUG-112/repro.py`, `output.txt`.

## Analysis (reporter's hypothesis)
Nothing sets the output encoding. On Windows with a piped stdout Python uses the ANSI code page.

## Suggested fix (optional)
At the top of `cli.main()`: `for s in (sys.stdout, sys.stderr): s.reconfigure(encoding="utf-8", errors="replace")` (Python 3.7+). In `cmd_wake` print first, persist state after (or catch `UnicodeEncodeError` per line). Mention `PYTHONUTF8=1` in README/MANUAL until fixed.

## Info needed
Gordon: do the orchestrator/monitor processes that call `wake`/`check` run with `PYTHONUTF8=1`? If not, events with `☼` have probably been lost already.

## Fix
`cli.main` reconfigures stdout/stderr to UTF-8 with `errors=replace` (never fatal); `wake_check(..., sink=print)` prints every line before it stores its state, so a print error loses no event. Tests: `test_bug112_*` (subprocess with `PYTHONIOENCODING=cp1252`).
