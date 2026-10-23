# BUG-086 perimeter.hold_pop 0 ("never hold max-pop") also switches off the small-fort guard of the office blocker
Status: fixed in the integration audit I4 commit (offline, live-untested): the office guard uses the default (30 citizens)
when hold_pop is 0; the perimeter's own meaning of 0 (never hold) is unchanged
Severity: medium (a fort of 7 citizens would be stopped from growing by a vacant office it cannot fill, once the player set
hold_pop 0 for the perimeter)
Found: 2026-10-23, integration audit I4 (package A4's blocker reads package A2's key)
Module: `lua/dfllm/readiness.lua` (`evaluate`, `pcfg`), `config/reflex.json` `perimeter.hold_pop`

## Actual
DECISIONS 19: the vacant-office blocker (BUG-055) and the open-perimeter hold (FR-70) apply only from `perimeter.hold_pop`
(30) citizens, so a young fort is never stopped by what it cannot yet fill. The office blocker took its bound from the
perimeter key but not its meaning of 0: `hold_pop 0` is "the perimeter never holds max-pop" (test_open_perimeter), and the
guard `hp0 > 0 and cit < hp0` is false for 0, so the guard was off and a vacant CHIEF_MEDICAL_DWARF for 7 days made a fort
of 7 citizens R0 `office` (max-pop frozen at its population, the wake repeating).

## Cause
`readiness.evaluate` (merge f900594, A4 on A2): the guard borrowed `pcfg(K, 'hold_pop')` and treated 0 like any bound.

## Fix
`hold_pop` 0 gives the guard the default `M.PERIM.hold_pop` (30); `offices.blocker_days` 0 remains the way to switch the
office blocker off. Nothing changes for the shipped config.

## Tests
`tests/lua/test_integration_i4.lua` (fails on 9bcb14f): hold_pop 0, 7 citizens, a CHIEF_MEDICAL_DWARF vacant for 9 days:
no `office` blocker; 40 citizens: still blocked; the default config unchanged.
