# BUG-092 The cloth note of the fiber crops repeats every game week, 19 seconds at timestream speed
Status: fixed in the integration audit J2 commit (offline, live-untested)
Severity: low (noise: three warn lines a minute in kern.log while the condition stands)
Found: integration audit J2 (2026-10-23), the weekly messages of the merged packages read against `util/cadence`
Module: `lua/dfllm/economy.lua` (`M.fiber_note`), `tests/lua/test_integration_i3_farm.lua`

## Actual
`M.fiber_note` (BUG-084) logs "cloth short by N ... and autofarm is off" once a game week while autofarm is off and cloth is short,
timed by game ticks alone (`r.now - af.fnote < 7 * DAY`). A game week is 19 s at 450 ticks a second, so the line came three times a
minute for as long as the cloth was short (the case BUG-008 built `util/cadence` for: a repeat waits max(7 game days, 10 minutes)).
kern.log rotates at 1 MB: about 36 hours of it.

## Fix
`fiber_note` keeps a cadence record (`CAD.mark`, `CAD.elapsed` with `CAD.WALL_S`), `CAD.quiet` while the condition is gone, so a new
episode inside the cadence waits too. An old state held a tick number there: no record, one more line.

## Test (fails on c038ce9)
`tests/lua/test_integration_i3_farm.lua`: the line goes out at once, not again after 8 more game days at mock speed, again after ten
minutes of the (virtual) wall clock.

Related: BUG-084, BUG-008
