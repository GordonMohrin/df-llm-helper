# BUG-175 A transformation wave of one tick is split in two events, the late one names dead units, bite is missed for syndrome-found units
Status: fixed (offline, live-untested)
Severity: high (curse_kill asked after the first unit only; '4 were-form' with 5 of 7 named units dead)
Found: 2026-10-29, live test round 2 i2 (M4-TRANSFORM, NEW3; skeptic d181: 8 reports at tick 290923210 -> #33735 one unit, #33752 +1199 ticks)
Module: `lua/dfllm/curse.lua` (`M.report`, `M.take`, `M.wave`, `M.flush`, `emit_transform`, `M.look`)

## Actual
- `M.report` flushed after every report: the first report of a wave went out alone, the rest waited `curse_every` (600 ticks).
- `emit_transform` did not check that a queued unit was still alive or still in that form, and counted the dead as were-forms.
- `bite` was `fresh` only; a unit known by the bite's syndrome (src `syndrome`) never got it.

## Fix
- `M.report` takes the report and every other curse report of the same game time (report `year` and `time`, newest 60 reports; `M.wave`), then
  flushes once; a report taken with an earlier one's wave is not taken twice. The flush works while the game is paused (the curse popup).
- Before a TRANSFORM goes out the dead leave the list (`forget`); queued entries of dead or reverted units are dropped (the text says
  'N more died first'); nothing is emitted when none is left.
- `bite` also when the record's source is `syndrome` (report and sheet path).

## Tests
`tests/lua/test_curse_live2.lua` BUG-175 (three tests; fail on b805745).

## Live check
At the next full moon with several cursed: `dfllm events --type TRANSFORM`: one event per wave tick with all ids (`more` = n-1), followed by one
curse_kill naming all; a unit that died before the event is not in `ids`; a bitten unit (inspect what=curse src syndrome) has `bite 1`.
Uncertain: whether DF 53.16 fills `report.year` / `report.time` (if not, the wave is not batched and the old split remains).
