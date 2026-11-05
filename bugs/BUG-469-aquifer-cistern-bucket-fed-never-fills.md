# BUG-469 Run 16d i4 Mazelanterns y403/y404, Run 16c i3 Castletongs: the cisterns were built bucket-fed 87-106 tiles from the pond zone and their wells stayed dry for 30 days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-05, round 29 notes (`runs/run-16a..16d/FR-BUGS.md`), main 59d6abb
Module: dfpilot/cmd.py:cistern_fill_guard, dfpilot/bp/sites.py:fill_source (far), dfpilot/plan.py:_cistern_due, _aq_cistern_due, cistern_gate

## Actual
i4: `CISTERN_DRY` for y403s1b3 and y404s1b2 (and the earlier c1a1a9aafc298e0701): `well 18315 at 60,74,137 dry for 30 days: bucket-fed (pond zone 18327); carry from: zone 17696 at 164,170,137 (103 tiles)`. i3: the same, 106 tiles. The bp files hold `cistern` with `water: bed`, `path: ''`: the plain bucket-fed cistern, not the aquifer cistern (`p.water=aquifer`, BUG-262/434), although an aquifer level was known (the fort had an aqshaft).

## Root causes
1. Nothing chose between the two kinds at placement: `bp.place cistern` (the player's hand, follow's `cistern_water` request, `plan propose`'s `_cistern_due`) took the default `water=bed` without a path = a pond zone and bucket carriers. `sites.fill_source` said `ok` for any revealed water the core reaches on foot, 100 steps away included; `cistern_gate` and `_cistern_due` only looked at `ok is False`.
2. `wake._request_access` returned at once when the PROJECT_REQUEST had no tile (`at`), which is the i4 patient_water case (BUG-434's request carried only `n`): nothing was ever placed for the patients.

## Fix
- `sites.fill_source` adds `far` (steps > `BUCKET_STEPS_MAX` 40, the `water.patient_far` / `drink_far` distance); `ok` stays (the water is there).
- `cmd.cistern_fill_guard` (called by `_place` for every `cistern`): no pipe, not aquifer, and `fill_source` says `ok False` or `far`: a known aquifer level -> `p.water=aquifer` (noted in `PLACE_NOTES`), else BpError "would stay dry" (no dead cistern is built any more). Pipe and aquifer cisterns, a near water, an unknown fill (`ok None`, no core) pass unchanged.
- `plan._cistern_due` does not draft the plain cistern for far water; `_aq_cistern_due` takes it when an aquifer level is known; `cistern_gate` warns for far water too.
- `wake._request_access`: patient_water without a tile places the aquifer cistern (`cistern_water` job, `p.water=aquifer`; the guard above refuses it without a known aquifer / on a heavy one); no_water without a tile still waits for one.

## Tests
`tests/test_bug469_473_f29.py` (fill_source far, the guard's cases, place calls the guard for cisterns only, follow with and without a tile, an aquifer project answers once).

## Live check
`bp.place tpl=cistern` in a fort with water > 40 steps away: the reply note `BUG-469: ... placed p.water=aquifer`; the basin on the aquifer level (observe mode keeps its rough walls, BUG-262), the well wet within days. Open: whether the aquifer seep fills a basin on a light level in time (BUG-262's own live check); a heavy level is refused by `bp sites cistern` as before; the floodgate/seal pattern is the aqshaft's own and was not added to the basin.
