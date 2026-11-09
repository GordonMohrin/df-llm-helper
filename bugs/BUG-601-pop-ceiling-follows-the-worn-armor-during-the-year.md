# BUG-601 The population ceiling does not follow the soldiers' armor between two year plans
Status: fixed (offline, live-untested)
Severity: high (Brotherarrow grew 81 -> 88 -> 86 with the soldiers in armor worn 7-39 %, then fell 86 -> 2 to an invasion of 57)
Found: 2026-11-09, Run 16b i2 Brotherarrow y405-y414 (`Ceiling 88 (armor 56 %)` from the plan, worn 7-39 % through the year), Run 16c i3 Sealcertain y422 (pop raised to 100 beside worn 27-31 %)
Module: `lua/dfllm/readiness.lua` (`armor_shortfall`, `evaluate`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
`plan.defense_cap` (BUG-377 / BUG-533) holds the ceiling at the population while the soldiers' armor is short, with room for a wave while worn is 40 % or more. It is evaluated when the plan is made (once a year): the plan of Brotherarrow saw worn 56 % (soft: population 80 + room 8 = 88) and the ceiling stayed 88 while worn fell to 7-39 %.

## Root cause
The kernel's own defence hold (`defense_short`, BUG-481) knew only the trap shortfall; the armor part of the gap lived in the year plan (plan.py `defense_gaps`) and was never read again between two plans.

## Fix
`readiness.armor_shortfall` (new): soldiers in a fort of `DEF.armor_pop` (20) citizens or more wearing under `DEF.worn_pct` (60) percent of their uniform slots (the military KPI) is a shortfall in PEACE, joined to the trap shortfall (same clock `st.dt`, same `DEF.grace_days` 20, from `DEF.hold_pop` 30 citizens): after the grace days max-pop is held at the population (ceiling why `defense_short`); a soft gap (worn at least `GROW.worn_pct` 40, traps at least half the target) leaves `growth_room` for one wave, a bare army leaves none, and the hold lifts at 60 %. No R0 blocker. State `ready.as` names it (schema.py + contract.lua), `pop.hold` shows `defense_short N` / `N+`.

## Tests
`tests/lua/test_bug600_601_perimeter_armor.lua` (2: held at 100 with worn 30, 110+ with worn 50, lifted with 70; a dip shorter than the grace days, a fort of 15 and an army of 0 hold nothing)

## Live check
`status` pop line: `max-pop 100 (defense_short)` with `ready.as` `armor worn N % < 60 % (S soldiers)` after 20 game days of worn under 60 %; the ceiling follows worn up again.

## Open
The mark and the grace are the Python plan's numbers (`DEFENSE_WORN` 60, `GROWTH_WORN` 40) as constants of readiness (not config); worn is the KPI "filled uniform slots", so a squad in off-duty months reads as it wears; the kit fixes of BUG-598 / BUG-599 are what lifts the hold.
