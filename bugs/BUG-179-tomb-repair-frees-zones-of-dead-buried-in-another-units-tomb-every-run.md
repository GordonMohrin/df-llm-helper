# BUG-179 The tomb repair frees the same 20 zones every run: the dead owner lies in a coffin under another unit's tomb zone and DF gives the zone straight back
Status: fixed (offline, live-untested)
Severity: high (20 tomb acts a run wasted for years; `freed 20, assigned 0, entomb 0` in every care run, again.churn 562 since boot)
Found: 2026-10-29, live test round 2 instance i4 (BUG-133c, NEW3; skeptic confirmed)
Module: `lua/dfllm/care.lua` (`tomb_repair`, `lock_scan`, `M.lockstate`, `M.held_own`)

## Actual
`tomb_repair` set `z.free = 'elsewhere'` for every zone whose dead owner had remains in any coffin (`r.held_by[u]`). In the i4 fort the
remains lay in coffins under ANOTHER dead unit's tomb zone (coffin 11128 under zone 11139 of 35247 held about 45 skeletons). DF does not count such
a body as entombed and assigned the owner's own free zone back within 18 ticks (also with preserve-tombs/preserve-rooms off). `lock_scan` counted
the re-gift as churn, but nothing fed it back, so the same zones were freed every run.

## Fix
- `M.held_own(e, uid)`: the holding coffin counts as uid's own tomb only when a tomb zone over it is assigned to uid or no zone over it has an
  owner. Otherwise the owner's zone is kept (`acts.kept_shared`).
- `release` records the owner it freed (`lk.fown`); `lock_scan` records a zone DF gave back to that same owner (`lk.regive[zone] = owner`), and
  `tomb_repair` never frees that (zone, owner) pair again (`acts.kept_regive`). Both maps forget zones that vanish (memory only, since boot).

## Tests
`tests/lua/test_fix2_tombs.lua`: a shared coffin keeps the zone (an unowned holder: freed as before); a zone re-given to the same owner is freed once only (both fail on b805745).

## Live check
In i4 (region2-site90) after `dfllm reload`: two care runs; kern.log `tombs: ... freed N` falls to 0 (no `freed 20` loop); `inspect tombs` `acts.kept_shared` about 20 or more, `acts.kept_regive` >= 0; `lock.churn` stops rising; zone 23336 stays with owner 33030 and is not freed again.
