# BUG-555 Unequipped soldiers stay unequipped while the fort is never quiet: the armor refit runs in danger-free PEACE only, the sortie refusal does not say what is missing
Status: fixed (offline, live-untested)
Severity: high (no sortie against a lone predator in Kern+; soldiers worn 19-35 % with 18 free body armors and 17 free metal weapons)
Found: 2026-11-06, Run 16a i1 Basementflew y422 (`runs/run-16a/FR-BUGS.md` "OBS y422 sum d22: Ceratosaurus ... squad.sortie verweigert: 0 von 6 Soldaten Waffe+Koerperruestung (worn 19%) - 12 Sol, 18 freie Metallwaffen liegen, Ausruestung greift nicht (uniform-unstick bringt 9-47%, faellt zurueck)"; kern.log `gear: ... body 18/6 ok ... weapon 12/6 ok` with `worn 35%`, `uniform-unstick ... worn 35% before, 35% now`; read only)
Module: `lua/dfllm/military.lua` (`M.refit`, `M.unfit_text`, `M.kit_missing`)

## Actual
Economy counted body 18/6, head 23/6, weapon 12/6 `ok` (free pieces), yet the six soldiers of squad A wore 35 % and the sortie against the ceratosaurus in Kern+ was refused: `squad A is not equipped: 0 of 6 soldiers hold a real weapon and wear body armor (< 30 %)`. `uniform-unstick --all --free` changed nothing. The refusal did not say which part was missing nor that the pieces lay free.

## Root cause
`military.lua:3823` (before) called `M.refit` only `if mode == 'PEACE'`, and `M.refit` returned at `M.danger(K)`, which is true in every mode but PEACE and in PEACE with a lockdown or a hostile in sight. That refit (dfllm.kit `refit_plan`) is the only step that re-specs an empty armor slot whose material the free pieces do not match (a metal spec with other material free, and the reverse). In that fort a stegosaurus kept the fort in ALERT for 1,375 of every 2,000 ticks (BUG-554), then a BREACH: the refit never ran and the empty slots stayed. `M.unfit_text` only counted.

## Fix
- `M.refit`: with a danger about (alert, lockdown, hostile in sight, recovery, drill) it runs after one game day instead of `refit_days`; in a SIEGE or BREACH only for a squad below `UNFIT_PCT` (the one that is refused the sortie), also after one day; quiet PEACE keeps `refit_days`. The squad pass calls it in every mode.
- `M.kit_missing` / `unfit_text` / the stand-down line: `(missing: weapon 3, wooden training weapon only 1, body armor 3; free: 17 melee weapons, 18 body armors; the pieces lie free but are not worn: ...)` (`M.free_weapons` counts free non-training melee weapons).

## Tests
`tests/lua/test_fr100_kit.lua` (the refit now runs in an ALERT after a day: positions 2.. go to any material), `tests/lua/test_bug510_unfit.lua` (the refusal names the missing parts and the free pieces).

## Live check
A fort that is often in ALERT: kern.log `military: squad A: body of N positions to any material (the slot stayed empty, other pieces lie free)` within a game day of the first unequipped alert; `squad.sortie` refusals carry `(missing: ...; free: ...)`.
Open: what DF does with the re-specced slots (fetching takes game time; soldiers confined by the civil alert may not reach the pieces) is live-only. The free count is DF's flags, not reachability: pieces in flooded or walled stores still show as free. Weapons are not re-specced by the refit (only armor categories); wooden training weapons are swapped by `ensure_weapons` as before.
