# BUG-100: `wake` silently stops reporting new events once `events.log` has more than 5000 lines

- **Status:** fixed in 626d04f
- **Severity:** S2
- **Area:** `df_llm_helper/wake.py:68-83` (offset logic), `df_llm_helper/toolsfs.py:137-140` (`events_lines`)
- **Reported:** 2026-10-02, commit `50cee52` (Python code identical to `6dedd96`)
- **Environment:** Windows 11 Pro 10.0.26200, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`. The repro itself needs no game.

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-100/repro.py          # temp folder only; prints the output below
```
By hand: `wake` once (baseline) on a tools folder whose `events.log` has 5100 lines, append one line
`CRITICAL 10:05:00 [FEATURE_BEAST] A forgotten beast has come!`, run `wake` again.

## Expected
`WAKE critical [FEATURE_BEAST]: A forgotten beast has come! -> python -m df_llm_helper digest` (this is what happens with 100 lines in the file, see control run).

## Actual
```
===== events.log with 100 filler lines ... =====      (control, works)
WAKE critical [FEATURE_BEAST]: A forgotten beast has come! -> python -m df_llm_helper digest

===== events.log with 5100 filler lines ... =====      (BUG)
$ python -m df_llm_helper --config ...\cfg.yaml wake        <- second run, after the CRITICAL line was appended
[exit=0]                                                    <- no output at all, event lost
```
Full output: `Bugs/evidence/BUG-100/output.txt`.

## Evidence
`Bugs/evidence/BUG-100/repro.py`, `Bugs/evidence/BUG-100/output.txt`.
Real-world relevance: the live `events.log` (`dwarf-fortress/tools/events.log`, written by the old watcher since Sept.) has **4326 lines** today
(4001 of them CRITICAL/KRITISCH, 54 different tags). It crosses 5000 lines within the next few game days; from then on `wake --loop`
would never wake the orchestrator again, with no warning (wake is the only alarm path for ambushes/deaths when nobody calls `check`).

## Analysis (reporter's hypothesis)
`wake_check` reads `tools.events_lines(5000)` = the **last** 5000 lines (a sliding window) but stores the absolute count `st["events_n"] = len(lines)` (wake.py:83)
and next time evaluates `lines[off:]` (wake.py:69-70, `off = events_n`). Once the file has >= 5000 lines, `len(lines)` is always 5000, so
`off = 5000` and `lines[5000:]` is always empty. New lines are never seen. (`if off > len(lines): off = 0` only handles a truncated file.)

## Suggested fix (optional)
Store the byte offset (or total line count of the whole file) instead of the window length, e.g. read the file with `read_text_tolerant(...).splitlines()` without the
`[-last_n:]` cut for the offset bookkeeping, or remember the last seen line (hash + text) and search it in the window. Add a unit test with a 6000-line log.

## Info needed
None for the cloud session. Gordon: if `wake --loop` has been running unattended for days, check whether `tools/events.log` is already above 5000 lines (then wake has been blind since).

## Fix
`wake` keeps a byte offset (`events_pos`) plus a hash of the first line (`events_head`) via `ToolsDir.events_since()`; a shorter file or a new first line = rotated log -> read from the start; an incomplete last line waits for the next call; old `events_n` state is migrated. Tests: `tests/test_bugs_core.py::test_bug100_*` (6000-line log, rotation, old state).
