# BUG-089 The turnover's hold for the army's worn % is logged at every upkeep the % moves
Status: fixed in fb84d83 (offline, live-untested): the log line of a hold is keyed by its reason
without the numbers, once per close and reason; the state still shows the current %
Severity: low (noise: kern.log line every 3,600 ticks, 8 real seconds at ~450 ticks a second, for up to nine months of
game time)
Found: 2026-10-23, integration audit J1 (hypothesis 7: the cadence of the new kern.log lines at timestream speed)
Module: `lua/dfllm/military.lua` (`rot_turn` `hold`, `rot_note`)

## Actual
CHANGELOG/FR-79: "kern.log per batch and per hold (once per edge and reason)". `rot_note` (military.lua:1427-1435) keeps the
signature of the last line and logs only a changed one, at most every `NOTE_EVERY` (2,400) ticks. `hold` (:1439-1445) built
the signature from `ed.close .. info.why`, and `info.why` for the worn hold is `held: worn 38% < 40%`: the % of the army
moves with every soldier who dresses, undresses, dies or arrives, so every upkeep (3,600 ticks, more than `NOTE_EVERY`) had
a new signature and a new line, for as long as the turnover waited (the whole off period, up to 84 upkeeps).

## Cause
The signature carried the numbers of the text. The other holds (`mode SIEGE`, `lockdown`, `hostile`, `no leader`) carry none,
which is why the unit test of D1 did not see it.

## Fix
The signature is the reason with its numbers replaced (`worn #% < #%`); the text of the line and the state keep them.

## Tests
`tests/lua/test_integration_j1.lua` (fails on c038ce9, 7 lines for 8 upkeeps): the army's worn % moves by one each upkeep
while the leavers wear kit: one line `waits (worn ...)` for the close, the state shows the current %, the turnover runs once
the army wears its kit.

Related: FR-79, BUG-032 (`NOTE_EVERY`), util/cadence.lua
