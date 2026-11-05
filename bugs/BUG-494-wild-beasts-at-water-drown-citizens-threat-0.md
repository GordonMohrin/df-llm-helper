# BUG-494 A wild pack at the brook drowns citizens, threat 0: water beasts are no PREDATOR candidate, fishers keep fishing
Status: fixed (offline, live-untested)
Severity: high (5 citizens dead in 4 years, nothing woke the player, the fishers kept walking to the water)
Found: 2026-11-05, Run 16b i2 Brotherarrow y372-y375 (FR-BUGS "Hibbertopterus-Rudel toetet Zwerge (Ertrinken)"; round 31 note "i2 R9"): a Hibbertopterus pack lived in the brook through the embark rectangle, bred (33 births in the gamelog), interrupted a carpenter and grabbed the fisher; `status` said `threat 0 vis`, `census.h.vis` 0, events only `DEATH unknown (missing)` and, five days later, `drowned`
Module: `lua/dfllm/sense.lua` (`predator`, `water_beast`, `wild_publish`), `lua/dfllm/economy.lua` (`fish_want`, `M.fish_start`), `dfpilot/schema.py` (WATER_PREDATOR)

## Actual
`sense.predator` lists a wild unit only if it stands on the citizens' walk group (`getWalkableGroup(u.pos) == citizens_group()`) and, outside, near an entrance (FR-33). A unit in a brook or river tile is on no walk group (0) and `consider` then drops it as "on another walk group, cannot fly" (live L7 rule). `big_wild` (BUG-439) needs a roofed tile. So a large or predatory animal in the water is invisible to PREDATOR, INTRUDER, the census and the threat module. Nothing restricted the Fisherdwarves detail or the fishing zone beside it.

## Fix
- `sense.water_beast` (every active unit in the hostile scan): a visible wild unit (no tame, fort-controlled, citizen, resident, invader, merchant, diplomat, visitor, caged, chained) that is a LARGE_PREDATOR (raws), a marked killer (BUG-421) or of a large body (`size_cur` >= `sense.WATER.big` 100,000 cm3) AND stands in or beside a water tile (`flow_size` >= 1, liquid water; magma is none) is a water beast. `census.w` = `{tick, n, list, near, hold}` (CONTRACTS 6.6); list entries carry race, size, tile kind, brook/river, reach (1 on the citizens' walk group, 2 from a bank tile, 0 out of reach) and the distance to the nearest civilian.
- It is not a hostile: no lockdown, no mode change (a brook is no entrance). The new event WATER_PREDATOR (A, once per unit and 7,200 ticks, urgent in dfpilot's wake) names race, size, position, distance, reach and carries the exact `squad.sortie` command (`d.cmd`) when a sortie squad exists, so the player decides.
- `census.w.hold` is 1 while a beast is within `WATER.near` (60) tiles of a civilian and for `WATER.hold` (2,400) ticks after: economy's `fish_want` returns 0 (`water beast`), the Fisherdwarves leave the detail at once (also members the player added, like in a siege), and `fish_start` places no new fishing zone.
- Not done: water hauling for wells and hospitals is not restricted by the kernel (the event's next-step text says: no well, fishing, bridge or dig beside that water); nothing was added that digs near water.

## Tests
`tests/lua/test_bug494_water_beast.lua` (4: census.w and WATER_PREDATOR once, no hostile and no lockdown, reach from the bank, the sortie command; small, dry, tame, merchant, caged and magma units are none; the hold lasts 2,400 ticks and a beast far from every citizen does not hold; sense.describe), `tests/lua/test_economy_food.lua` (+1: the fishers leave and stay off), `tests/test_bug494_496_wild_water.py`.

## Live check
With a big wild animal in a brook within 60 tiles of a citizen: `dfllm status` shows a WATER_PREDATOR line with race, size, reach and cmd, `inspect census` has `w`, the Fisherdwarves detail is empty (kern.log "sense: N wild beast(s) at water"), `threat` stays 0. After the beast left, 2,400 ticks later the fishers come back. Unknown live: DF's liquid_type value for brook tiles (assumed 0 = water, flow_size 1-7) and whether a Hibbertopterus' `size_cur` is above 100,000 (a LARGE_PREDATOR flag or a killer mark counts too).
