# BUG-136 The curse logic starved behind care's paced full run: no CURSE_MOON in six moons, a frozen moon in the state, a missed wave
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: high (the 4-day warning never came; the status named a moon 20 days past)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier
Module: `lua/dfllm/kern.lua` (frame loop: `M.watch`), `lua/dfllm/util/k_mock.lua`, `lua/dfllm/care.lua` (`M.watch_every`, `M.watch`,
`M.state`), `lua/dfllm/curse.lua` (`M.watch`, `build_view`, `M.view`, `finish`), `docs/v2/CONTRACTS.md` section 3.2

## Actual
- `grep -c CURSE_MOON events.jsonl` = 0 across the moons d26, d51, d77 (and d129, d155, d180 on the verifier's run), though the
  estimate was right.
- At d101 the status said `next full moon ~d77 (in 11 d)`; `CU.view()` stayed `{mi:5, mo:155}` from d151 to d179.
- Urvad was a werecavy d77-79 (race checked live), the game wrote no report, and no TRANSFORM came.

## Causes
`M.look` (the race), `moon_event`, `forget` and `build_view` ran only in care's multi-slice full run (care.lua:729-731, 3789-3791). Under
pacing and demotion (`care demoted x8`, `care waited 30 s for a slice`) that run came every 10-31 game days, longer than the 4-day window
(`curse_moon_lead`). `build_view` froze `mo`/`mi` at build time. `pcall(moon_event)` discarded its error.

## Fix
- kern (and k_mock): a module may declare `M.watch(K)` with `M.watch_every = {ticks = N}`: called every N game ticks on its own clock,
  before the step check, also while a run is in hand; never paced, never demoted, not stretched (CONTRACTS section 3.2).
- care: `watch_every = {ticks = DAY}`; `M.watch` runs `curse.watch`: `M.look` for the known cursed ids and for every citizen with
  `curse_year >= 0` (a few field reads per citizen), then `finish` (re-key names, forget, flush, CURSE_MOON, the view).
- The state view keeps the moon's phase; `CU.view(K)` computes `mo`/`mi` when care publishes its state.
- A failing `moon_event` is logged (`care curse moon: ...`).

## Tests
`tests/lua/test_curse_live.lua` (care at factor 512: CURSE_MOON, the moon of today, the race wave, a bitten citizen),
`tests/lua/test_curse_live_kern.lua` (the watch clock on the real kernel), `tests/test_curse_live.py` (the contract text).
