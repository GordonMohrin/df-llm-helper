# BUG-615 A Pond zone beside a dry or shallow well keeps the citizens thirsting; the stall ladder takes one zone and only after days
Status: fixed (offline, live-untested)
Severity: high (2 children dead of thirst in Run 16c i3 Wallfree y380)
Found: 2026-11-09, Run 16c i3 Wallfree y380 (well 17785 at 94,51,146 over 2/7 water, shallow; FillPond worker 26273 stood 3 days at 93,50,146; children 26482 / 26556 died at 94,50,146 at thirst 75,000)
Module: `lua/dfllm/water.lua` (`M.pond_block`, `unstick`, `DEFAULTS.pond_*`)

## Actual
The thirst DECISION (`thirst: 2 citizens thirsty, drink 0 days`, every 7 days) named the shallow well and offered `inspect what=water_sources`, `bp sites cistern`, a farm: nothing that acts. The only actor was the BUG-507 stall ladder: a FillPond worker had to stand `stall_days` (3) with thirst over 25,000, then `unstick` removed ONE pond zone (`break` after the first, water.lua `unstick`). Wallfree had two zones beside the well (18050, 17776): after the first went, the next FillPond worker stood again, and `water.unstick unit=` by the player answered 'holds no water job the kernel has watched' for the two dying children (they held no job). The children died 19 game days after the first thirst question.

## Root cause
- `water.lua unstick` (the `pond_remove` rung): `break` after the first zone within `pond_near + 1`.
- No rule looked at the citizens: a thirsty citizen standing at a well that gives nothing was only a text in `drink_fix` (thirst >= `well_thirst` 50,000) for a question that offers no action.
- `pond_loops` / `M.loops` handle only WET wells (the pond pours the well's own water back).

## Fix
- `M.pond_block(K, c, r, p, now)` (called in `finish` after `M.loops`): a built well with no accepted water (dry or shallow, not a loop, not marked for removal) with a Pond zone within `pond_near + 1` tiles while a non-patient citizen at `pond_thirst` (25,000) or more stands within `pond_reach` (4) tiles of it on its level: ALL its Pond zones go at once (`act.pond_remove`, remembered in `p.prm`), plus DECISION_NEEDED class A `pond_blocks_well` (`q`, `units`, `cmds`, `well`, `ponds`; once per well per `pond_block_every` 3 days unless a zone went). The well of a cistern room (`M.cistern_room`: it fills by its pond) is report only (`held` 1). `pond_block = false`: off. `phase_units` collects `r.athirst` for it.
- `unstick`: every Pond zone within reach goes (at most `pond_per_run`), not only the first.
- `wake.py`: `pond_blocks_well` is an urgent decision id.

## Tests
`tests/lua/test_bug615_617_water_deaths.lua` (BUG-615: both zones in the first run, shallow well, no zone for a citizen under 25,000 / far away / at a wet well, the cistern room's well held and the decision repeats only after 3 days, `pond_block = false`, the ladder takes every zone)

## Live check
`kern.log` `water: N citizen(s) at thirst T stand at the dry well ... pond zone(s) ... removed`, event `DECISION_NEEDED pond_blocks_well`; the next water run no longer lists the zones. Open: whether DF gives the citizens water at a well whose sump is dry once the zone is gone (they then go to the accepted water zone on their own, as after `water.unstick` in Wallfree); a pond zone that really fills a cistern sump in a non-cistern-room fort is removed too (a citizen at thirst 25,000 beside it says it does not work).
