# BUG-421: two `dfhack-run` calls (`claude/mil`, `claude/mil guard`) took 8-9 s while the same calls normally take 0.07 s (not reproducible; Gordon's "main thread blocked" suspicion)

- **Status:** fixed, live check pending (see TESTPLAN-live) [diagnostics reviewed + python tests pass; root cause needs live stall.log]
- **Severity:** S3 (becomes S2 if it turns out that a periodic script blocks the main thread for seconds)
- **Area:** unknown - candidates: periodic DFHack jobs (`claude-watchdog`/`claude-watchdog-alert`, `claude-milguard` via `tempo.schedule`, `claude-tempo`), DF autosave, the `mil` script itself
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, date `27. Granite, Jahr 118`); `claude/watchdog status` -> `running: true`, `claude/mil guard` -> `guard: true, checks: 361`

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
time ./dfhack-run.exe claude/mil            # 8.24 s once (first call of a batch)
time ./dfhack-run.exe claude/mil guard      # 9.40 s once (first call of another batch)
```
Control: `Bugs/evidence/BUG-421/poll.py` calls `claude/alert` every second for 150 s while I only read source files: maximum 0.85 s, two more samples above 0.3 s, **no** 8-9 s stall. Idle gaps of 45-60 s before a call (`claude/alert`) were also fast (0.07-0.09 s). `claude/mil` repeated immediately (0.07-0.19 s) and after 30/60 s of idle (0.08 s) was fast, so it is not a first-load / compile cost of `mil.lua`.

## Expected
Every read answers in < 1 s (the game is paused; only periodic jobs run).

## Actual
Two isolated 8-9 s waits. A `dfhack-run` request is served by the main (game) thread, so the wait means that something occupied that thread for ~8-9 s (a periodic Lua job, an autosave (`C:\Users\admin\AppData\Roaming\Bay 12 Games\Dwarf Fortress\save\autosave 3` is in the script path), or the OS).

## Evidence
`Bugs/evidence/BUG-421/slow_calls_observed.txt`, `poll_claude_alert_every_1s_150x.txt`, `poll.py`.

## Analysis (reporter's hypothesis)
No script-specific cause found: `mil.lua` status work is trivial. The `milguard` job (`mil.lua:guard_tick`, every 60 calendar ticks, `GF.handle(GF.scan())`) and `watchdog` (`alert_check`, `corpses`, `feed`, `buildingplan status`) run on frames even while paused, and `watchdog.check()` every 600 ticks iterates all items several times (barrels, wood, corpses, corpse pieces, drink...). The item loops in `supplies()` / `corpses()` (all barrels, wood, corpses, corpse pieces; `claude/muell status` counts ~15,700 loose items) could plausibly cost seconds once per interval. A real-time job `auslastung` (5 s measure / 30 s item scan) is currently off (`running:false`).

## Suggested fix (optional)
Measure from inside: add a `claude/watchdog timing` that records `os.clock()` per sub-step of `check()` into the answer, then let the player run `claude/watchdog timing` during an observed stall.

## Info needed
- Player: do you see the game freeze for a few seconds periodically (autosave every N minutes? every 600/1200 ticks?). Please run `Bugs/evidence/BUG-421/poll.py 600` (10 minutes, changes nothing) and send `poll.log`; a regular spike period identifies the job.

Decided (player delegated the decision): make the client robust and self-diagnosing (stall log, stall period, a failure needs 2 consecutive timeouts); the root cause is confirmed later from the live stall log.

## Fix
Not reproducible here. Diagnostic in 4774f54: `claude/watchdog status` now reports `timing` (last/max ms per sub-step of the watchdog jobs). Player: after a stall run `claude/watchdog status` and attach `timing`, plus `poll.py 600`.

Robustness and self-diagnosis (42d0018):
- `RealClient` appends every dfhack-run call slower than 3 s (also timeouts) to `<tools>/out/stall.log` (ISO time, epoch, duration, ok|fail|timeout, command), rotated at 1 MB (`stall.log.1`); `df_llm_helper/stalllog.py`.
- `python -m df_llm_helper perf status` prints `stall log: N stalls (... calls > 3 s, ... timeouts, longest ... s), stall period: median interval ... s, last ...; top: <commands>` (calls within 15 s are one stall).
- Watcher: a single timeout of the report-id read only skips the pass (`waechter.alive` is refreshed); 2 consecutive timeouts are a failure (BUG-106 behaviour). The heartbeat is file based and never depends on a game call; the guard has no failure counter (an unreadable snapshot only blocks `tempo on` for that cycle, fail closed, unchanged). A 9 s stall is below the 40 s client timeout anyway.
- Tests: `tests/test_bugs_decided.py::test_bug421_*`.
- Root cause: still to be confirmed. After the next live stall send `tools/out/stall.log`, `perf status` and `claude/watchdog status` (timing).
