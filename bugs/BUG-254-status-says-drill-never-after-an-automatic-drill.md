# BUG-254 status said 'drill never' right after an automatic drill had run
Status: fixed (offline, live-untested)
Severity: low (the player could not tell that the drill caused the lowering that killed 24165)
Found: 2026-10-29, Run 15b Earthboat (y374), fix6-crush
Module: `dfpilot/brief.py` (`last_drill`, `drill_note`, `pop_items` drill line)

## Actual
`drill never (auto: retry wait)` while an automatic drill had just run and failed: `ready.drill_age` is the age of the last
PASSED drill, so failed drills never showed.

## Fix
The drill line adds ` [last auto drill 2d ago failed]` (`[last drill ...]` for a manual one, `, bridges not down in time` for
DRILL_RESULT d.restore -1) when the newest DRILL_RESULT of the last game year failed after the last pass; status finds it with one
bounded backwards scan of the event log (`DRILL_SCAN` 20,000 events), the brief in its B digest. DRILL_RESULT carries `d.why`
(BUG-251) to tell automatic from manual drills.

## Tests
`tests/test_fix6_crush.py` (3 for the line, fail on 2b9c009).

## Live check
After an automatic drill that failed: `dfpilot status` shows `drill never (auto: retry wait; run dfllm cmd drill) [last auto drill
Nd ago failed]`.
