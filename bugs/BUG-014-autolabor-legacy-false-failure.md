# BUG-014 AUTOLABOR_LEGACY says "mode monitor failed, still legacy" although the mode was switched
Status: fixed in 413f614 (offline, live-untested)
Severity: low (the fix works, the report is wrong and raises a class A interrupt for nothing)
Found: 2026-10-15 15:05, Run 9 save autosave 1 (y371), dfpilot main 677bc3e, `dfllm reload`
Module: `lua/dfllm/baseline.lua` (autolabor guard, BUG-010 fix)

## Actual
```
#10881 y371 sum d5 A AUTOLABOR_LEGACY autolabor ran in legacy mode (the engine of the Run 9 crashes, found at boot):
       autolabor mode monitor failed, still legacy [after=legacy fixed=0 why=boot]
commands.log:  baseline act.run ["autolabor","mode","monitor"] ok   (twice, with "autolabor","status" in between)
dfhack-run autolabor mode        ->  Mode: monitor (starvation warnings)
dfhack-run autolabor status      ->  Error: The plugin is not enabled in legacy mode.
```
So the plugin is in monitor mode afterwards (the goal of BUG-010 is reached) but the event reports `after=legacy fixed=0` and is an
unacked class A event.

## Expected
`AUTOLABOR_LEGACY ... switched to monitor` (fixed=1), or no event beyond a log line when the switch worked. The check that decides
"still legacy" probably reads `autolabor status` right after the switch (its output now is the error text above) or the mode before the switch settled.

## Fix proposal
Verify with `autolabor mode` (prints `Mode: monitor`) or the Lua plugin API instead of `status`; treat "not enabled in legacy mode" as success.

Related: BUG-010

## Cause
`legacy_guard` read the engine back with `autolabor status` right after `autolabor mode monitor`. In every mode but
legacy the plugin answers `Error: The plugin is not enabled in legacy mode.`; `parse_engine` found no `mode:` field and
fell back to the first mode word in the text, "legacy", so `after=legacy fixed=0`. The same answer made every later
guard run (the first task of the full apply, as in commands.log: status, mode monitor, status twice) see legacy again
and switch once more.

## Fix (413f614, offline)
- `parse_engine`: a text with `not enabled in legacy mode` means the legacy engine is not running (`nil, false`), also
  when the command failed (act.run's error text is parsed for that answer only).
- The switch is read back with `autolabor mode` (`Mode: monitor (starvation warnings)` -> monitor; allowlisted: the
  `autolabor` entry has `mode`), and only when it prints no engine with `autolabor status` (the not-legacy answer ->
  `not legacy`). A later guard run sees no legacy engine and switches nothing.
- A switch that worked is one kern.log line (`autolabor was enabled in legacy mode (boot): set to monitor (read back:
  monitor)`), no event; only a failed switch emits AUTOLABOR_LEGACY (A, `fixed=0`), again at most every 10 min while it
  stays failed. RULES §7 and the CONTRACTS event row say so.
- Tests (`tests/lua/test_baseline.lua`): the plugin mock answers as DF 53.16 did live (status error in non-legacy modes,
  with a failed or an ok exit status; `autolabor mode` with or without a mode line): fixed, no event, one log line,
  switched once, the next guard run does nothing; a refused switch is still AUTOLABOR_LEGACY fixed=0; economy's daily
  read fixes a later legacy switch with a log line; `parse_engine` of the error text. `tests/test_bugfixes_live15.py`:
  `autolabor mode` is allowlisted.

## Live check (Run 9 save)
Setup: autolabor enabled in legacy mode (a save where it came back legacy after the load, or the player sets it in
DFHack by hand; the kernel's allowlist never permits `autolabor mode legacy`). `dfllm reload` (or load the save).
Expected commands.log: `baseline act.run ["autolabor","status"] ok`, `["autolabor","mode","monitor"] ok`,
`["autolabor","mode"] ok`; the guard of the full apply's first task reads `["autolabor","status"]` (ok or ERR with the
not-legacy text) and switches nothing (the labor task's own `labormanager mode`, `autolabor mode monitor`, `enable
autolabor` follow as before); kern.log `autolabor was enabled in legacy mode (boot): set to monitor (read back: monitor)`;
`dfllm events --cls A` has no new AUTOLABOR_LEGACY; `dfhack-run autolabor mode` prints `Mode: monitor`. On a save where
autolabor is already in monitor mode: no switch at all (only the status read).
