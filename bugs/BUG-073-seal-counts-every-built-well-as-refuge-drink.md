# BUG-073 seal rates the refuge by every built well, readiness by wet wells: one dry well freed Tiefe+ from the breach_days window
Status: fixed in 1135ff0 (offline, live-untested): seal's burrow audit counts the wells water calls wet (`water.wet_wells`) as
drink, as readiness' `refuge_ok` does; a dry well counts for nothing; REFUGE_FAIL says `1 well, none wet`
Severity: high (wrong decision: a refuge without water was taken at the WET level and kept past the 7 days while
readiness said `refuge_dry`; only BUG-031 (b)'s thirst mark could move the citizens out again)
Found: 2026-10-17 (BUG-040 left it as a documented choice), decided 2026-10-23 (DECISIONS 6)
Module: `lua/dfllm/seal.lua` (`burrow_audit`, `rate`, `choose`, `leave_why`, `M.refuge_drink`)

## Actual
`inspect refuge` of Run 11 y453: Tiefe+ drink 0, wells 1, wwet 0. readiness: R0 `refuge_dry` (water `refuge_ok` 0). seal:
`wet = true`, so `choose` took Tiefe+ at the WET level and `rwet` (seal.lua `choose`) let the BREACH level take it after
the breach days had run out.

## Cause (seal.lua at f17e2b3)
1. `burrow_audit` set `a.wet = a.exists and (a.drink >= need.drink or a.wells > 0)` (601) and left `drink` out of `a.why`
   when `a.wells > 0` (590): `a.wells` counts every built well on the burrow's tiles (the audit pass, `wells` field).
2. The audit already read `water.wet_wells` into `a.wwet` (770-771, BUG-040) but only reported it. The comment at 587-589
   called the difference deliberate (BUG-040: the alert holds a dry refuge until the citizens get thirsty).
3. `choose`: `rwet = au[refuge].wet == true` frees the refuge from `breach_open` (window) and `leave_why` (`window`) uses
   the same flag, so a dry well kept the refuge for ever.

## Fix
- `a.wells` is replaced by `wells = a.wwet ~= nil and a.wwet or a.wells` in both lines: the wet wells when water has
  answered, the built wells when it has not (no module, no run yet, no burrow of that name, a fault): a boot never reads
  a dry refuge from silence.
- `a.why` and `rate`'s WET text say `drink 0<3, 1 well, none wet` (REFUGE_FAIL) when built wells are dry; `REFUGE_SWITCH`/
  `leave_why` texts are unchanged (they come from `rate`). `refuge_drink().wet` is the new rating; `wells` stays the built
  count, `wwet` the wet count.
- Safety: Tiefe+ is no longer taken at the WET level for a dry well; the BREACH level still takes it for the days
  (`breach_days`, no drink needed) so a breach with a dry refuge still has a place; after the days a dry refuge is
  refused like one with no well (citizens flee on their own, REFUGE_FAIL says so).

## Not decided offline
Whether water's `wet` matches the game's own thirst rule in a refuge with a barrel-fed cistern: the live data is
`dfllm cmd inspect '{"what":"refuge"}'` (`wells`, `wwet`, `drink`) beside `inspect water_sources` for the same tiles.

## Tests
`tests/lua/test_seal_refuge.lua`: BUG-073 (new; fails on f17e2b3): a dry well gives `wet = false`, the WET level refuses
Tiefe+ with `1 well, none wet`, an episode eight days in refuses it (old: held for ever), a wet well holds it. The BUG-040
test pinned `wet = true` for `wells 1, wwet 0`: now `false` (the decision of 2026-10-23); with water silent it stays `true`.
